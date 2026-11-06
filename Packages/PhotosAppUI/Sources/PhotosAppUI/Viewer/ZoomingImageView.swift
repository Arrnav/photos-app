import UIKit

/// A photo that fills the page at "fit" size and zooms with pinch or double-tap.
///
/// The image view always has the fitted size at zoom 1, whatever the bitmap's
/// resolution, so a higher-resolution image (preview → original) can be swapped
/// in mid-zoom without anything moving.
final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()

    /// Called when zooming in far enough that a sharper image is worth loading.
    var onNeedsSharperImage: (() -> Void)?
    var onZoomChanged: ((_ isZoomed: Bool) -> Void)?

    /// Width / height of the photo (known before any image arrives, from the asset).
    private(set) var aspectRatio: CGFloat = 1
    /// Pixel width of the best image that could be shown (the original), for the max zoom.
    private var fullPixelWidth: CGFloat = 0
    private var lastBoundsSize: CGSize = .zero
    private var askedForSharper = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        minimumZoomScale = 1

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.accessibilityIgnoresInvertColors = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        self.doubleTapRecognizer = doubleTap
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private(set) var doubleTapRecognizer: UITapGestureRecognizer!

    var isZoomed: Bool { zoomScale > minimumZoomScale + 0.01 }

    /// Where the photo is drawn, in `view`'s coordinates (the dismiss animation starts there).
    func imageFrame(in view: UIView?) -> CGRect {
        imageView.convert(imageView.bounds, to: view)
    }

    func prepare(aspectRatio: CGFloat, fullPixelWidth: CGFloat) {
        self.aspectRatio = aspectRatio > 0 && aspectRatio.isFinite ? aspectRatio : 1
        self.fullPixelWidth = fullPixelWidth
        askedForSharper = false
        imageView.image = nil
        zoomScale = 1
        lastBoundsSize = .zero
        setNeedsLayout()
    }

    /// Lets the next zoom-in ask for the sharper image again.
    func allowSharperImageRequest() {
        askedForSharper = false
    }

    func setImage(_ image: UIImage?) {
        imageView.image = image
    }

    func resetZoom(animated: Bool) {
        setZoomScale(minimumZoomScale, animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastBoundsSize, bounds.width > 0 else {
            centerImage()
            return
        }
        lastBoundsSize = bounds.size
        zoomScale = 1
        let fit = fittedSize(in: bounds.size)
        imageView.frame = CGRect(origin: .zero, size: fit)
        contentSize = fit
        let screenScale = window?.screen.scale ?? 3
        let fitPixels = fit.width * screenScale
        // Enough to see full resolution at 2× magnification, and never less than 3×.
        maximumZoomScale = max(3, fullPixelWidth > 0 ? (fullPixelWidth / max(fitPixels, 1)) * 2 : 3)
        centerImage()
    }

    private func fittedSize(in size: CGSize) -> CGSize {
        let viewRatio = size.width / max(size.height, 1)
        if aspectRatio > viewRatio {
            return CGSize(width: size.width, height: (size.width / aspectRatio).rounded())
        }
        return CGSize(width: (size.height * aspectRatio).rounded(), height: size.height)
    }

    private func centerImage() {
        let content = imageView.frame.size
        let horizontal = max(0, (bounds.width - content.width) / 2)
        let vertical = max(0, (bounds.height - content.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if isZoomed {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        // Zoom so the photo fills the screen (at least 2.5×), centred on the tap.
        let fit = imageView.frame.size
        let fillScale = max(bounds.width / max(fit.width, 1), bounds.height / max(fit.height, 1))
        let scale = min(maximumZoomScale, max(2.5, fillScale))
        let point = gesture.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        onZoomChanged?(isZoomed)
        if zoomScale > 1.4, !askedForSharper {
            askedForSharper = true
            onNeedsSharperImage?()
        }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        onZoomChanged?(isZoomed)
    }
}
