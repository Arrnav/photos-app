import Core
import ImmichCloud
import PhotosAppUI
import UIKit

/// Owns the app model, so background launches (upload results, background tasks) have it
/// even when no window is shown. Also gives a connected TV its own scene.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The Cloud server type is chosen here, and only here: the rest of the app talks to
    /// `CloudProvider`/`CloudConnection`, so another server needs only its own provider.
    @MainActor lazy var model = AppModel(accounts: AccountStore(), serverSettings: ServerSettings(), provider: ImmichProvider())

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated {
            model.registerBackgroundTasks()
            model.start()
        }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            model.handleBackgroundUploadEvents(identifier: identifier, completion: completionHandler)
        }
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if session.role == .windowExternalDisplayNonInteractive {
            let configuration = UISceneConfiguration(name: "External Display", sessionRole: session.role)
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
            return configuration
        }
        return UISceneConfiguration(name: nil, sessionRole: session.role)
    }
}
