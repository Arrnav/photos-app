import SwiftUI
import UIKit

/// The info panel that slides up under the photo, opaque so text
/// is always readable. Its content scrolls only when fully open.
final class InfoPanelView: UIView {
    let scrollView = UIScrollView()
    let host: UIHostingController<InfoView>

    init(model: InfoModel) {
        host = UIHostingController(rootView: InfoView(model: model))
        super.init(frame: .zero)
        backgroundColor = .systemGroupedBackground
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        host.sizingOptions = [.intrinsicContentSize]
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(host.view)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Where the panel and the photo sit for a given panel position.
struct InfoPanelGeometry {
    enum Stop: CaseIterable { case hidden, half, full }

    let height: CGFloat
    /// The photo's fitted frame (top and height) with the panel hidden.
    let photoTop: CGFloat
    let photoHeight: CGFloat

    func top(for stop: Stop) -> CGFloat {
        switch stop {
        case .hidden: height
        case .half: (height * 0.46).rounded()
        case .full: (height * 0.19).rounded()
        }
    }

    /// Half: the photo moves to the top (centred above the panel if it fits).
    /// Full: its bottom edge follows the panel. In between, linear.
    func photoTranslation(panelTop: CGFloat) -> CGFloat {
        let half = top(for: .half), full = top(for: .full)
        let halfPhotoTop = photoHeight <= half ? (half - photoHeight) / 2 : 0
        let fullPhotoTop = photoHeight <= full ? (full - photoHeight) / 2 : full - photoHeight
        let targetTop: CGFloat
        if panelTop >= half {
            let t = (height - panelTop) / max(height - half, 1)
            targetTop = photoTop + (halfPhotoTop - photoTop) * min(max(t, 0), 1)
        } else {
            let t = (half - panelTop) / max(half - full, 1)
            targetTop = halfPhotoTop + (fullPhotoTop - halfPhotoTop) * min(max(t, 0), 1)
        }
        return targetTop - photoTop
    }

    /// 0 with the panel hidden, 1 at half or above (chrome fades with this).
    func openness(panelTop: CGFloat) -> CGFloat {
        min(max((height - panelTop) / max(height - top(for: .half), 1), 0), 1)
    }

    /// The stop a release at `panelTop` moving at `velocity` (points/s, positive = down) settles on.
    func stop(releasedAt panelTop: CGFloat, velocity: CGFloat) -> Stop {
        let projected = panelTop + velocity * 0.18
        return Stop.allCases.min { abs(top(for: $0) - projected) < abs(top(for: $1) - projected) }!
    }
}
