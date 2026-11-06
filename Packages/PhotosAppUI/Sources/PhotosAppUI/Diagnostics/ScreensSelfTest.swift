import Persistence
import SwiftUI
import UIKit

/// Development aid (launch argument `-ScreensSelfTest`): shows the Recently Deleted grid and
/// Search on the device, saves snapshots to Library/Caches/selftest, and logs where Search's
/// field ends up against the keyboard's frame.
@MainActor
enum ScreensSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-ScreensSelfTest") }

    private static func say(_ text: String) {
        FileHandle.standardError.write(Data(("SCREENSTEST " + text + "\n").utf8))
    }

    static func run(session: LibrarySession) async {
        ScreenCapture.reset()
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let root = window.rootViewController else { return say("no window") }

        ScreenCapture.snapshot(window, name: "library")

        // Recently Deleted's layout, with Library photos and sample captions: the Face ID
        // albums (Hidden, Recently Deleted) themselves are never opened by a test.
        let items = Array(session.timeline.items.suffix(12))
        let trash = UIHostingController(rootView: NavigationStack {
            CollectionGridScreen(
                title: String(localized: "Recently Deleted"), items: items, session: session, bottomInset: 100,
                caption: { _ in TileCaption(text: "29 days") }, mode: .trash, infoTip: "tip"
            )
        })
        trash.modalPresentationStyle = .fullScreen
        root.present(trash, animated: false)
        try? await Task.sleep(for: .seconds(4))
        ScreenCapture.snapshot(window, name: "trash")
        trash.dismiss(animated: false)
        try? await Task.sleep(for: .seconds(1))

        // Hidden and Recently Deleted grids: the first row clears the header at the top, zoom
        // steps a level, and the pinch recognizer is live.
        // Never the Hidden album: it must only ever show after Face ID.
        for (name, mode) in [(String(localized: "Recently Deleted"), ViewerViewController.Mode.trash)] {
            let gridItems = items
            guard !gridItems.isEmpty else { say("\(name): no items"); continue }
            let key = "trash.columns"
            UserDefaults.standard.set(5, forKey: key)
            let state = LibraryUIState()
            let host = UIHostingController(rootView: NavigationStack {
                CollectionGridScreen(title: name, items: gridItems, session: session, bottomInset: 100, ui: state, mode: mode)
            })
            host.modalPresentationStyle = .fullScreen
            root.present(host, animated: false)
            try? await Task.sleep(for: .seconds(3))
            guard let grid = firstView(UICollectionView.self, in: host.view) else { say("\(name): no grid"); host.dismiss(animated: false); continue }
            grid.setContentOffset(CGPoint(x: 0, y: -grid.adjustedContentInset.top), animated: false)
            try? await Task.sleep(for: .seconds(0.5))
            let firstCell = grid.visibleCells.map { $0.convert($0.bounds, to: nil) }.min { $0.minY < $1.minY }
            let title = firstView(UILabel.self, in: host.view, where: { $0.text == name })
            say("\(name): \(gridItems.count) items, inset top \(Int(grid.adjustedContentInset.top)), first row top \(Int(firstCell?.minY ?? -1)), first row visible \((firstCell?.minY ?? -1) >= 0)")
            ScreenCapture.snapshot(window, name: "trash-top")
            let pinches = (grid.gestureRecognizers ?? []).compactMap { $0 as? UIPinchGestureRecognizer }
            say("\(name): pinch recognizers \(pinches.count), enabled \(pinches.allSatisfy(\.isEnabled)), title label found \(title != nil)")
            state.zoomCommand = .zoomIn
            try? await Task.sleep(for: .seconds(1.5))
            say("\(name): zoom in → \(UserDefaults.standard.integer(forKey: key)) columns")
            state.zoomCommand = .zoomOut
            try? await Task.sleep(for: .seconds(1.5))
            say("\(name): zoom out → \(UserDefaults.standard.integer(forKey: key)) columns")
            host.dismiss(animated: false)
            try? await Task.sleep(for: .seconds(1))
        }

        // Search: the field must sit just above the keyboard, on the first try.
        var keyboardTop: CGFloat?
        let token = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { keyboardTop = frame?.minY }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let search = UIHostingController(rootView: SearchScreen(session: session, ui: LibraryUIState()))
        search.modalPresentationStyle = .fullScreen
        root.present(search, animated: true)
        try? await Task.sleep(for: .seconds(3))
        ScreenCapture.snapshot(window, name: "search")
        let field = firstTextField(in: search.view)
        let fieldBottom = field.map { $0.convert($0.bounds, to: nil).maxY }
        say("search: keyboard top \(keyboardTop.map { "\(Int($0))" } ?? "none"), field bottom \(fieldBottom.map { "\(Int($0))" } ?? "none"), "
            + "field above keyboard \(fieldBottom != nil && keyboardTop != nil && fieldBottom! <= keyboardTop!)")
        // Typing must keep the keyboard up (the first letter switches Home to results).
        field?.insertText("c")
        try? await Task.sleep(for: .seconds(1))
        field?.insertText("a")
        try? await Task.sleep(for: .seconds(1.5))
        let typingField = firstTextField(in: search.view)
        say("typing: same field \(typingField === field), still editing \(typingField?.isFirstResponder == true), text \(typingField?.text ?? "nil")")
        ScreenCapture.snapshot(window, name: "search-typing")
        search.dismiss(animated: false)
        say("done")
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView, where match: (T) -> Bool = { _ in true }) -> T? {
        if let found = view as? T, match(found) { return found }
        for subview in view.subviews { if let found = firstView(type, in: subview, where: match) { return found } }
        return nil
    }

    private static func firstTextField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        for subview in view.subviews { if let found = firstTextField(in: subview) { return found } }
        return nil
    }
}
