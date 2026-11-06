import SwiftUI
import UIKit

/// How much of the screen the keyboard covers, from UIKit's own notifications.
/// SwiftUI's keyboard avoidance sometimes misses a keyboard that comes up while a full-screen
/// cover is still sliding in (Search focuses its field at once), which left the field behind
/// the keyboard; following the keyboard's frame directly doesn't.
@MainActor
@Observable
final class KeyboardObserver {
    private(set) var height: CGFloat = 0
    private(set) var animationDuration: Double = 0.25
    @ObservationIgnored private var tokens: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let hides = note.name == UIResponder.keyboardWillHideNotification
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let screen = UIScreen.main.bounds
                    self.animationDuration = max(duration, 0.2)
                    self.height = hides ? 0 : max(0, screen.maxY - frame.minY)
                }
            })
        }
    }

    isolated deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
