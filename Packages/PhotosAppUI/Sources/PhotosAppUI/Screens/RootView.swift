import SwiftUI

/// Sign-in when no account is active, otherwise the tabs.
public struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.isSignedIn {
                PhotosShell(model: model)
            } else {
                NavigationStack {
                    SignInView(model: model)
                }
            }
        }
        .onAppear { model.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.sceneBecameActive()
            case .background: model.sceneEnteredBackground()
            default: break
            }
        }
    }
}

struct ComingSoonView: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: "hammer", description: Text(detail))
                .navigationTitle(title)
        }
    }
}
