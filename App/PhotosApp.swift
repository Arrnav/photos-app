import Core
import PhotosAppUI
import SwiftUI

@main
struct PhotosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView(model: appDelegate.model)
        }
    }
}
