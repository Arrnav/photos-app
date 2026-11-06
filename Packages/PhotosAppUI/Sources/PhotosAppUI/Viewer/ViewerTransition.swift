import UIKit

/// The grid side of the zoom transition.
@MainActor
protocol ViewerTransitionSource: AnyObject {
    /// The tile's frame in window coordinates and its current image. With
    /// `scrollIntoView`, the grid first scrolls so the tile is visible.
    func transitionTile(for itemID: String, scrollIntoView: Bool) -> (frame: CGRect, image: UIImage?)?
    /// Hides one tile while the photo is flying to or from it (nil shows all).
    func setTransitionTileHidden(_ itemID: String?)
}

/// Zooms the photo out of its grid tile when opening the viewer, and back into
/// the tile of whatever photo is showing when it closes (also after swipe-to-dismiss).
final class ViewerTransitionController: NSObject, UIViewControllerTransitioningDelegate {
    weak var source: ViewerTransitionSource?

    init(source: ViewerTransitionSource) {
        self.source = source
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        ZoomAnimator(isPresenting: true, source: self.source)
    }

    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        ZoomAnimator(isPresenting: false, source: source)
    }
}

private final class ZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let isPresenting: Bool
    weak var source: ViewerTransitionSource?

    init(isPresenting: Bool, source: ViewerTransitionSource?) {
        self.isPresenting = isPresenting
        self.source = source
    }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        // Quicker than the first versions (0.42 / 0.38, then 0.35 / 0.32 s).
        isPresenting ? 0.3 : 0.27
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        MainActor.assumeIsolated {
            if isPresenting { present(context) } else { dismiss(context) }
        }
    }

    @MainActor
    private func present(_ context: any UIViewControllerContextTransitioning) {
        guard let viewer = context.viewController(forKey: .to) as? ViewerViewController else {
            context.completeTransition(false)
            return
        }
        let container = context.containerView
        viewer.view.frame = context.finalFrame(for: viewer)
        container.addSubview(viewer.view)
        viewer.view.layoutIfNeeded()

        let itemID = viewer.currentItem?.id
        let tile = itemID.flatMap { source?.transitionTile(for: $0, scrollIntoView: false) }
        let target = viewer.fittedImageFrame(in: container)
        viewer.setTransitionState(.presenting)

        guard let tile, let itemID else {
            // No tile to zoom from: fade in.
            viewer.view.alpha = 0
            UIView.animate(withDuration: 0.2) { viewer.view.alpha = 1 } completion: { _ in
                viewer.setTransitionState(.idle)
                context.completeTransition(true)
            }
            return
        }

        let flying = Self.flyingImageView(image: tile.image ?? viewer.currentPageImage, frame: container.convert(tile.frame, from: nil))
        container.addSubview(flying)
        source?.setTransitionTileHidden(itemID)

        UIView.animate(springDuration: transitionDuration(using: context), bounce: 0.08) {
            flying.frame = target
            viewer.setTransitionState(.presented)
        } completion: { _ in
            flying.removeFromSuperview()
            self.source?.setTransitionTileHidden(nil)
            viewer.setTransitionState(.idle)
            context.completeTransition(true)
        }
    }

    @MainActor
    private func dismiss(_ context: any UIViewControllerContextTransitioning) {
        guard let viewer = context.viewController(forKey: .from) as? ViewerViewController else {
            context.completeTransition(false)
            return
        }
        let container = context.containerView
        let start = viewer.currentImageFrame(in: container)
        let image = viewer.currentPageImage
        let itemID = viewer.currentItem?.id
        let tile = itemID.flatMap { source?.transitionTile(for: $0, scrollIntoView: true) }

        guard let tile, let itemID, let image else {
            UIView.animate(withDuration: 0.2) { viewer.view.alpha = 0 } completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
            return
        }

        let flying = Self.flyingImageView(image: image, frame: start)
        container.addSubview(flying)
        viewer.setTransitionState(.dismissing)
        source?.setTransitionTileHidden(itemID)

        UIView.animate(springDuration: transitionDuration(using: context), bounce: 0) {
            flying.frame = container.convert(tile.frame, from: nil)
            viewer.setTransitionState(.dismissed)
        } completion: { _ in
            flying.removeFromSuperview()
            self.source?.setTransitionTileHidden(nil)
            context.completeTransition(!context.transitionWasCancelled)
        }
    }

    /// Aspect-fill and clipped: animating its frame from the fitted photo to the
    /// square tile crops smoothly.
    @MainActor
    private static func flyingImageView(image: UIImage?, frame: CGRect) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.frame = frame
        view.accessibilityIgnoresInvertColors = true
        return view
    }
}
