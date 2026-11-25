import SwiftUI
import AVFoundation

@main
struct RitornelloApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            PlayerWebView()
                .ignoresSafeArea()
                .background(Color(uiColor: .ritornelloBackground).ignoresSafeArea())
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AudioSessionManager.activate()
        application.beginReceivingRemoteControlEvents()
        return true
    }
}

enum AudioSessionManager {
    /// Categoria "playback": l'audio continua con lo schermo bloccato e con il tasto silenzioso attivo.
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("Sessione audio non attivata: \(error)")
        }
    }
}

extension UIColor {
    static let ritornelloBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.082, green: 0.075, blue: 0.173, alpha: 1)
            : UIColor(red: 0.933, green: 0.941, blue: 0.965, alpha: 1)
    }
}
