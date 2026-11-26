import Foundation
import AVFoundation
import YouTubeKit

/// Un brano della coda, come lo manda la pagina.
struct QueueItem {
    let id: String
    var title: String
    var artist: String
    var thumb: String
    var start: Double?
    var end: Double?

    var hasChorus: Bool {
        guard let s = start, let e = end else { return false }
        return e > s
    }

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        title = (dict["title"] as? String) ?? ""
        artist = (dict["artist"] as? String) ?? ""
        thumb = (dict["thumb"] as? String) ?? ""
        start = (dict["start"] as? NSNumber)?.doubleValue
        end = (dict["end"] as? NSNumber)?.doubleValue
    }
}

/// Lettore audio nativo: suona l'audio dei brani YouTube con AVPlayer,
/// quindi continua anche a schermo bloccato, e gestisce da solo coda e loop del ritornello.
final class NativePlayer: NSObject {
    var onState: (([String: Any]) -> Void)?

    private let player = AVPlayer()
    private var queue: [QueueItem] = []
    private var index = 0
    private var repeats = 0
    private var mode = "full"
    private var loops = 0
    private(set) var wantsPlaying = false
    private var loading = false
    private var stage = ""
    private var readyTimer: DispatchWorkItem?
    private var errorText = ""
    private var pendingSeek: Double?
    private var retried = false
    private var failStreak = 0

    private var boundaryObserver: Any?
    private var periodicObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var urlCache: [String: (url: URL, date: Date)] = [:]
    private var lastEmit = Date.distantPast

    override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.emit(force: true) }
        }
        periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                          queue: .main) { [weak self] time in
            self?.periodic(time.seconds)
        }
    }

    private var current: QueueItem? { queue.indices.contains(index) ? queue[index] : nil }
    private func cm(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: 600) }
    private var now: Double { let t = player.currentTime().seconds; return t.isFinite ? t : 0 }
    private var duration: Double {
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }

    // MARK: Comandi

    func play(queue items: [QueueItem], index i: Int, repeats n: Int) {
        guard !items.isEmpty else { return }
        queue = items
        index = min(max(0, i), items.count - 1)
        repeats = max(0, n)
        wantsPlaying = true
        retried = false
        failStreak = 0
        load(at: nil)
    }

    func pause() {
        wantsPlaying = false
        player.pause()
        emit(force: true)
    }

    func resume() {
        wantsPlaying = true
        if player.currentItem == nil || player.currentItem?.status == .failed {
            let at = now
            load(at: at > 0 ? at : nil)
            return
        }
        AudioSessionManager.activate()
        player.play()
        emit(force: true)
    }

    func toggle() { if wantsPlaying { pause() } else { resume() } }

    func resumeIfWanted() { if wantsPlaying { resume() } }

    func advance(_ d: Int) {
        guard !queue.isEmpty else { return }
        index = ((index + d) % queue.count + queue.count) % queue.count
        wantsPlaying = true
        retried = false
        load(at: nil)
    }

    func seek(to t: Double) {
        if player.currentItem?.status == .readyToPlay {
            player.seek(to: cm(t), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            pendingSeek = t
        }
        emit(force: true)
    }

    func setMode(_ m: String, at: Double?) {
        guard let item = current else { return }
        mode = (m == "chorus" && item.hasChorus) ? "chorus" : "full"
        loops = 0
        installBoundary()
        let target: Double? = at ?? (mode == "chorus" ? item.start : nil)
        if let t = target { seek(to: t) }
        resume()
    }

    func setMarkers(id: String, start: Double?, end: Double?, preview: Double?) {
        for k in queue.indices where queue[k].id == id {
            queue[k].start = start
            queue[k].end = end
        }
        guard let item = current, item.id == id else { return }
        if !item.hasChorus { mode = "full" }
        installBoundary()
        if let p = preview, mode == "chorus" { seek(to: p) }
        emit(force: true)
    }

    func setRepeats(_ n: Int) {
        repeats = max(0, n)
        emit(force: true)
    }

    // MARK: Caricamento

    private func load(at startAt: Double?) {
        guard let item = current else { return }
        loadTask?.cancel()
        teardownItem()
        player.pause()
        player.replaceCurrentItem(with: nil)
        mode = item.hasChorus ? "chorus" : "full"
        loops = 0
        errorText = ""
        stage = ""
        loading = true
        pendingSeek = startAt ?? (item.hasChorus ? item.start : nil)
        emit(force: true)

        let id = item.id
        if let cached = urlCache[id], Date().timeIntervalSince(cached.date) < 3 * 3600 {
            startItem(url: cached.url)
            return
        }
        stage = "Cerco l’audio su YouTube…"
        emit(force: true)
        loadTask = Task { [weak self] in
            do {
                let url = try await NativePlayer.fetchStreamURL(id) { message in
                    DispatchQueue.main.async {
                        guard let self = self, self.current?.id == id, self.loading else { return }
                        self.stage = message
                        self.emit(force: true)
                    }
                }
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self = self, self.current?.id == id else { return }
                    self.urlCache[id] = (url, Date())
                    self.startItem(url: url)
                }
            } catch {
                if Task.isCancelled { return }
                let detail = NativePlayer.describe(error)
                await MainActor.run {
                    guard let self = self, self.current?.id == id else { return }
                    self.fail("Non riesco a recuperare l’audio da YouTube (\(detail)).")
                }
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .timedOut: return "tempo scaduto"
            case .notConnectedToInternet: return "nessuna connessione"
            case .resourceUnavailable: return "nessun audio riproducibile"
            default: return "errore di rete \(u.code.rawValue)"
            }
        }
        let text = String(describing: error)
        return text.count > 120 ? String(text.prefix(120)) + "…" : text
    }

    /// Trova l'indirizzo dell'audio: prima estrazione locale, poi il server di riserva della libreria.
    /// Ogni tentativo ha un tempo massimo, così non resta mai appeso.
    private static func fetchStreamURL(_ id: String, progress: @escaping (String) -> Void) async throws -> URL {
        var lastError: Error = URLError(.cannotLoadFromNetwork)
        do {
            return try await withTimeout(15) { try await NativePlayer.pickStream(YouTube(videoID: id, methods: [.local])) }
        } catch {
            lastError = error
        }
        progress("Provo il metodo di riserva…")
        do {
            return try await withTimeout(25) { try await NativePlayer.pickStream(YouTube(videoID: id, methods: [.remote])) }
        } catch {
            lastError = error
        }
        throw lastError
    }

    private static func pickStream(_ yt: YouTube) async throws -> URL {
        let streams = try await yt.streams
        if let audio = streams.filterAudioOnly().filter({ $0.isNativelyPlayable }).highestAudioBitrateStream() {
            return audio.url
        }
        if let both = streams.filterVideoAndAudio().filter({ $0.isNativelyPlayable }).highestResolutionStream() {
            return both.url
        }
        throw URLError(.resourceUnavailable)
    }

    private static func withTimeout(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> URL) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            group.cancelAll()
            return first
        }
    }

    private func startItem(url: URL) {
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async { self?.statusChanged(it) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self] _ in
            self?.itemEnded()
        }
        failObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                                              object: item, queue: .main) { [weak self] _ in
            self?.streamFailed(reason: "riproduzione interrotta")
        }
        player.replaceCurrentItem(with: item)
        installBoundary()
        stage = "Scarico l’audio…"
        emit(force: true)
        readyTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self, self.player.currentItem === item, item.status != .readyToPlay else { return }
            self.streamFailed(reason: "l’audio non arriva (tempo scaduto)")
        }
        readyTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timer)
        if wantsPlaying {
            AudioSessionManager.activate()
            player.play()
        }
    }

    private func statusChanged(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            readyTimer?.cancel()
            stage = ""
            loading = false
            retried = false
            failStreak = 0
            if let t = pendingSeek {
                pendingSeek = nil
                player.seek(to: cm(t), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if wantsPlaying { player.play() }
            emit(force: true)
        case .failed:
            streamFailed(reason: item.error.map { NativePlayer.describe($0) } ?? "errore del lettore")
        default:
            break
        }
    }

    private func streamFailed(reason: String) {
        readyTimer?.cancel()
        guard let item = current else { return }
        urlCache[item.id] = nil
        if !retried {
            retried = true
            let at = now
            load(at: at > 0 ? at : nil)
            return
        }
        fail("YouTube non riesce a riprodurre questo brano (\(reason)).")
    }

    private func fail(_ message: String) {
        readyTimer?.cancel()
        stage = ""
        loading = false
        errorText = message
        failStreak += 1
        emit(force: true)
        // In una playlist passa al brano dopo, senza girare a vuoto se non funziona niente.
        if queue.count > 1 && failStreak < queue.count && wantsPlaying {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, self.wantsPlaying else { return }
                self.index = (self.index + 1) % self.queue.count
                self.retried = false
                self.load(at: nil)
            }
        } else {
            wantsPlaying = false
            player.pause()
            emit(force: true)
        }
    }

    private func teardownItem() {
        readyTimer?.cancel()
        if let b = boundaryObserver { player.removeTimeObserver(b); boundaryObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        if let o = failObserver { NotificationCenter.default.removeObserver(o); failObserver = nil }
        statusObservation = nil
    }

    // MARK: Loop del ritornello

    private func installBoundary() {
        if let b = boundaryObserver { player.removeTimeObserver(b); boundaryObserver = nil }
        guard mode == "chorus", let item = current, item.hasChorus, let e = item.end else { return }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: cm(e))], queue: .main) { [weak self] in
            self?.chorusFinished()
        }
    }

    private func chorusFinished() {
        guard mode == "chorus", let item = current, item.hasChorus, let s = item.start else { return }
        loops += 1
        if repeats > 0 && loops >= repeats {
            advance(1)
            return
        }
        player.seek(to: cm(s), toleranceBefore: .zero, toleranceAfter: .zero)
        if wantsPlaying { player.play() }
        emit(force: true)
    }

    private func itemEnded() {
        guard let item = current else { return }
        if item.hasChorus {
            if mode == "chorus" { chorusFinished() } else { setMode("chorus", at: nil) }
        } else {
            advance(1)
        }
    }

    private func periodic(_ t: Double) {
        if mode == "chorus", pendingSeek == nil, player.timeControlStatus == .playing,
           let item = current, item.hasChorus, let s = item.start, let e = item.end, t.isFinite {
            // Se per qualche motivo si è finiti fuori dal ritornello, torna dentro.
            if t > e + 0.6 || t < s - 1.0 {
                player.seek(to: cm(s), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        emit(force: false)
    }

    // MARK: Stato verso la pagina e la schermata di blocco

    private func emit(force: Bool) {
        let date = Date()
        if !force && date.timeIntervalSince(lastEmit) < 0.5 { return }
        lastEmit = date
        guard let item = current else {
            onState?(["index": -1])
            return
        }
        let status = player.timeControlStatus
        let playing = status == .playing || (wantsPlaying && status == .waitingToPlayAtSpecifiedRate)
        onState?([
            "index": index,
            "id": item.id,
            "title": item.title,
            "artist": item.artist,
            "thumb": item.thumb,
            "playing": playing,
            "rate": status == .playing ? 1.0 : 0.0,
            "time": now,
            "duration": duration,
            "mode": mode,
            "loops": loops,
            "loading": loading,
            "stage": stage,
            "error": errorText
        ])
    }
}
