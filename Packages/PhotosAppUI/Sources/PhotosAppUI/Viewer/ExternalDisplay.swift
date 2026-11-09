import AVFoundation
import Observation
import UIKit

/// What a connected TV shows while the viewer is open (Screen Mirroring or a cable):
/// the current photo or video, full screen, with no controls. The system creates the
/// external display's scene itself, so this state is shared rather than passed down.
@MainActor
@Observable
public final class ExternalDisplay {
    public static let shared = ExternalDisplay()

    private(set) var image: UIImage?
    private(set) var player: AVPlayer?
    /// True while a TV scene is connected.
    public private(set) var isConnected = false

    func show(image: UIImage?) {
        self.image = image
        player = nil
    }

    func show(player: AVPlayer) {
        self.player = player
    }

    func clear() {
        image = nil
        player = nil
    }

    fileprivate func setConnected(_ connected: Bool) { isConnected = connected }
}

/// The external display's scene: black, with the viewer's current photo or video.
public final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?

    public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ExternalDisplayViewController()
        window.isHidden = false
        self.window = window
        MainActor.assumeIsolated { ExternalDisplay.shared.setConnected(true) }
    }

    public func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        MainActor.assumeIsolated { ExternalDisplay.shared.setConnected(false) }
    }
}

private final class ExternalDisplayViewController: UIViewController {
    private let imageView = UIImageView()
    private var playerView: PlayerView?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(imageView)
        observe()
    }

    /// Re-renders whenever the shared state changes.
    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        let display = ExternalDisplay.shared
        if let player = display.player {
            if playerView?.playerLayer.player !== player {
                playerView?.removeFromSuperview()
                let view = PlayerView(player: player)
                view.frame = self.view.bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                self.view.addSubview(view)
                playerView = view
            }
        } else {
            playerView?.removeFromSuperview()
            playerView = nil
        }
        UIView.transition(with: imageView, duration: 0.25, options: .transitionCrossDissolve) {
            self.imageView.image = display.image
        }
    }
}
