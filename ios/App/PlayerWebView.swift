import SwiftUI
import UIKit
import WebKit
import AVFoundation
import MediaPlayer

struct PlayerWebView: UIViewRepresentable {
    func makeCoordinator() -> PlayerController { PlayerController() }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Evita che il WKUserContentController trattenga il controller per sempre.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// La pagina disegna l'interfaccia; l'audio lo suona NativePlayer, che funziona anche a schermo bloccato.
final class PlayerController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView?
    private let audio = NativePlayer()
    private var artworkURL = ""
    private var artwork: MPMediaItemArtwork?

    // MARK: Creazione

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()

        let content = WKUserContentController()
        content.add(WeakScriptHandler(self), name: "ritornello")
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        content.addUserScript(WKUserScript(source: "window.__RITORNELLO_NATIVE__ = true; window.__RITORNELLO_VERSION__ = '\(version)';",
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        config.userContentController = content

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.allowsBackForwardNavigationGestures = false
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        webView = wv

        audio.onState = { [weak self] state in self?.pushState(state) }
        setupRemoteCommands()
        observeAudioSession()
        loadApp()
        return wv
    }

    func loadApp() {
        guard let url = URL(string: Config.appURL) else { return }
        webView?.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData))
    }

    // MARK: Comandi dalla pagina

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "cmd": handleCommand(body)
        case "retry": loadApp()
        default: break
        }
    }

    private func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    private func handleCommand(_ b: [String: Any]) {
        guard let cmd = b["cmd"] as? String else { return }
        switch cmd {
        case "play":
            let items = ((b["queue"] as? [[String: Any]]) ?? []).compactMap { QueueItem(dict: $0) }
            let index = (b["index"] as? NSNumber)?.intValue ?? 0
            let repeats = (b["repeats"] as? NSNumber)?.intValue ?? 0
            audio.play(queue: items, index: index, repeats: repeats)
        case "pause":
            audio.pause()
        case "resume":
            audio.resume()
        case "next":
            audio.advance(1)
        case "prev":
            audio.advance(-1)
        case "seek":
            audio.seek(to: number(b["t"]) ?? 0)
        case "mode":
            audio.setMode((b["mode"] as? String) ?? "full", at: number(b["at"]))
        case "markers":
            audio.setMarkers(id: (b["id"] as? String) ?? "",
                             start: number(b["start"]), end: number(b["end"]), preview: number(b["preview"]))
        case "repeats":
            audio.setRepeats((b["n"] as? NSNumber)?.intValue ?? 0)
        default:
            break
        }
    }

    // MARK: Stato verso la pagina e la schermata di blocco

    private func pushState(_ state: [String: Any]) {
        updateNowPlaying(state)
        guard JSONSerialization.isValidJSONObject(state),
              let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.ritornelloNativeState && window.ritornelloNativeState(\(json))",
                                    completionHandler: nil)
    }

    private func updateNowPlaying(_ s: [String: Any]) {
        let title = (s["title"] as? String) ?? ""
        guard !title.isEmpty else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: (s["artist"] as? String) ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: number(s["time"]) ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: number(s["rate"]) ?? 0
        ]
        if let d = number(s["duration"]), d > 0 { info[MPMediaItemPropertyPlaybackDuration] = d }
        let art = (s["thumb"] as? String) ?? ""
        if art == artworkURL, let a = artwork { info[MPMediaItemPropertyArtwork] = a }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if art != artworkURL {
            artworkURL = art
            artwork = nil
            loadArtwork(art)
        }
    }

    private func loadArtwork(_ address: String) {
        guard !address.isEmpty, let url = URL(string: address) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self = self, self.artworkURL == address else { return }
                let a = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.artwork = a
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = a
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }.resume()
    }

    // MARK: Schermata di blocco, Centro di Controllo, cuffie, auto

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
        c.changePlaybackPositionCommand.isEnabled = false
        c.playCommand.addTarget { [weak self] _ in self?.audio.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.audio.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.audio.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.audio.advance(1); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.audio.advance(-1); return .success }
    }

    private func observeAudioSession() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(audioInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(routeChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
    }

    /// Dopo una telefonata o un'altra app che ha preso l'audio, riparte se stava suonando.
    @objc private func audioInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw),
              type == .ended else { return }
        let optionsRaw = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
        guard AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) else { return }
        DispatchQueue.main.async { [weak self] in self?.audio.resumeIfWanted() }
    }

    /// Cuffie scollegate: pausa, come fa qualsiasi app musicale.
    @objc private func routeChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { [weak self] in self?.audio.pause() }
    }

    // MARK: Navigazione

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        let appHost = URL(string: Config.appURL)?.host
        if isMainFrame, let scheme = url.scheme, scheme.hasPrefix("http"), url.host != appHost {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadApp()
    }

    private func showError(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        let html = """
        <!doctype html><html lang="it"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>
        body{font:17px -apple-system,system-ui,sans-serif;margin:0;padding:96px 24px;color:#1D1A3A;background:#EEF0F6}
        @media (prefers-color-scheme:dark){body{color:#EEEDF8;background:#15132C}}
        h2{font-size:26px;margin:0 0 10px}
        p{opacity:.75;margin:0 0 18px}
        button{font:inherit;font-weight:600;background:#D3226B;color:#fff;border:0;border-radius:999px;padding:12px 22px}
        </style></head><body>
        <h2>Non riesco ad aprire Ritornello</h2>
        <p>Controlla la connessione. Se è la prima volta, verifica che l’indirizzo in Config.swift sia quello del tuo sito GitHub Pages.</p>
        <button onclick="window.webkit.messageHandlers.ritornello.postMessage({type:'retry'})">Riprova</button>
        </body></html>
        """
        webView.map { $0.loadHTMLString(html, baseURL: nil) }
    }
}
