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

final class PlayerController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView?
    private var timer: Timer?
    private var inBackground = false
    private var playing = false
    private var wantsPlaying = false
    private var artworkURL = ""
    private var artwork: MPMediaItemArtwork?

    // MARK: Creazione

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.websiteDataStore = .default()

        let content = WKUserContentController()
        content.add(WeakScriptHandler(self), name: "ritornello")
        content.addUserScript(WKUserScript(source: "window.__RITORNELLO_NATIVE__ = true;",
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

        setupRemoteCommands()
        observeApp()
        startTimer()
        loadApp()
        return wv
    }

    func loadApp() {
        guard let url = URL(string: Config.appURL) else { return }
        webView?.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData))
    }

    private func js(_ code: String) {
        webView?.evaluateJavaScript("window.ritornelloNative && window.ritornelloNative.\(code)", completionHandler: nil)
    }

    // MARK: Messaggi dalla pagina

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "state": handleState(body)
        case "retry": loadApp()
        default: break
        }
    }

    private func handleState(_ b: [String: Any]) {
        playing = (b["playing"] as? Bool) ?? false
        wantsPlaying = (b["want"] as? Bool) ?? false
        let title = (b["title"] as? String) ?? ""
        let artist = (b["artist"] as? String) ?? ""
        let duration = (b["duration"] as? NSNumber)?.doubleValue ?? 0
        let position = (b["position"] as? NSNumber)?.doubleValue ?? 0
        let art = (b["artwork"] as? String) ?? ""

        guard !title.isEmpty else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
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

    // MARK: Comandi dalla schermata di blocco, cuffie, auto

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
        c.changePlaybackPositionCommand.isEnabled = false
        c.playCommand.addTarget { [weak self] _ in self?.js("play()"); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.js("pause()"); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.js("toggle()"); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.js("next()"); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.js("prev()"); return .success }
    }

    // MARK: Background

    private func observeApp() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(audioInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(routeChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
    }

    /// Quando l'app va in background WebKit mette in pausa il video: lo facciamo ripartire subito,
    /// con la sessione audio attiva continua a suonare solo l'audio.
    @objc private func didEnterBackground() {
        inBackground = true
        guard wantsPlaying else { return }
        AudioSessionManager.activate()
        for delay in [0.25, 0.8, 1.6, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.inBackground, self.wantsPlaying else { return }
                self.js("resumeIfWanted()")
            }
        }
    }

    @objc private func willEnterForeground() {
        inBackground = false
    }

    @objc private func audioInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw),
              type == .ended else { return }
        let optionsRaw = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
        guard AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) else { return }
        DispatchQueue.main.async { [weak self] in
            AudioSessionManager.activate()
            self?.js("resumeIfWanted()")
        }
    }

    /// Cuffie scollegate: pausa, come fa qualsiasi app musicale.
    @objc private func routeChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { [weak self] in self?.js("pause()") }
    }

    /// In background i timer della pagina rallentano: il controllo del loop lo fa l'app.
    private func startTimer() {
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, self.inBackground, self.wantsPlaying else { return }
            self.js("tick()")
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
