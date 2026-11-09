import UIKit

/// Video controls: a glass capsule above the
/// filmstrip with ▶︎/❚❚ at the left, a thin progress bar, and mute at the right; the icons
/// morph when tapped. While scrubbing the buttons fade out, the capsule grows taller and
/// shows the current time (with hundredths) on the left and the time remaining on the right.
final class VideoControlsView: UIView {
    private let background = UIVisualEffectView(effect: Glass.effect())
    private let playButton = UIButton(type: .custom)
    private let muteButton = UIButton(type: .custom)
    private let playIcon = UIImageView(image: UIImage(systemName: "play.fill"))
    private let muteIcon = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
    private let track = UIView()
    private let fill = UIView()
    private let currentLabel = UILabel()
    private let remainingLabel = UILabel()
    private var playback: VideoPlayback?
    private(set) var isScrubbing = false
    private var wasPlayingBeforeScrub = false
    private var shownPlaying: Bool?
    private var shownMuted: Bool?
    /// Called when scrubbing starts or ends (the viewer hides its other controls meanwhile).
    var onScrubbingChanged: ((Bool) -> Void)?

    private let restingHeight: CGFloat = 52
    private let scrubbingHeight: CGFloat = 76

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.isUserInteractionEnabled = false
        Glass.makeCapsule(background)
        addSubview(background)

        for (button, icon, label) in [(playButton, playIcon, String(localized: "Play")), (muteButton, muteIcon, String(localized: "Mute"))] {
            icon.tintColor = .label
            icon.contentMode = .center
            icon.preferredSymbolConfiguration = .init(pointSize: 20, weight: .semibold)
            icon.isUserInteractionEnabled = false
            button.addSubview(icon)
            button.accessibilityLabel = label
            addSubview(button)
        }
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        muteButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)

        track.backgroundColor = UIColor.label.withAlphaComponent(0.12)
        track.layer.cornerRadius = 4
        track.clipsToBounds = true
        fill.backgroundColor = UIColor.label.withAlphaComponent(0.45)
        track.addSubview(fill)
        addSubview(track)

        for label in [currentLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            label.textColor = .label
            label.alpha = 0
            addSubview(label)
        }
        remainingLabel.textAlignment = .right

        // Scrub anywhere along the capsule (not on the buttons).
        let scrub = UILongPressGestureRecognizer(target: self, action: #selector(scrubbed(_:)))
        scrub.minimumPressDuration = 0
        scrub.delegate = self
        addGestureRecognizer(scrub)
        isAccessibilityElement = false
        track.isAccessibilityElement = true
        track.accessibilityLabel = String(localized: "Playback position")
        track.accessibilityTraits = .adjustable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 16
        let height = isScrubbing ? scrubbingHeight : restingHeight
        let capsule = CGRect(x: inset, y: bounds.height - height, width: bounds.width - inset * 2, height: height)
        background.frame = capsule
        background.layer.cornerRadius = 26
        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true
        playButton.frame = CGRect(x: capsule.minX + 8, y: capsule.minY, width: 48, height: restingHeight)
        muteButton.frame = CGRect(x: capsule.maxX - 56, y: capsule.minY, width: 48, height: restingHeight)
        playIcon.frame = playButton.bounds
        muteIcon.frame = muteButton.bounds
        let barHeight: CGFloat = 8
        if isScrubbing {
            track.frame = CGRect(x: capsule.minX + 22, y: capsule.maxY - 22 - barHeight, width: capsule.width - 44, height: barHeight)
            currentLabel.frame = CGRect(x: track.frame.minX, y: capsule.minY + 12, width: track.frame.width / 2, height: 24)
            remainingLabel.frame = CGRect(x: track.frame.midX, y: capsule.minY + 12, width: track.frame.width / 2, height: 24)
        } else {
            let left = playButton.frame.maxX + 4, right = muteButton.frame.minX - 4
            track.frame = CGRect(x: left, y: capsule.midY - barHeight / 2, width: right - left, height: barHeight)
        }
        updateFill()
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: scrubbingHeight) }

    /// Shows the controls for `playback` (nil hides them).
    func bind(_ playback: VideoPlayback?) {
        self.playback = playback
        refresh()
    }

    func refresh() {
        guard let playback else { return }
        if shownPlaying != playback.isPlaying {
            shownPlaying = playback.isPlaying
            playIcon.setSymbolImage(UIImage(systemName: playback.isPlaying ? "pause.fill" : "play.fill")!, contentTransition: .replace)
            playButton.accessibilityLabel = playback.isPlaying ? String(localized: "Pause") : String(localized: "Play")
        }
        if shownMuted != playback.isMuted {
            shownMuted = playback.isMuted
            muteIcon.setSymbolImage(UIImage(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")!, contentTransition: .replace)
            muteButton.accessibilityLabel = playback.isMuted ? String(localized: "Unmute") : String(localized: "Mute")
        }
        track.accessibilityValue = "\(Self.format(playback.currentTime, hundredths: false)) of \(Self.format(playback.duration, hundredths: false))"
        if isScrubbing { updateTimes() }
        updateFill()
    }

    private var fraction: Double {
        guard let playback, playback.duration > 0 else { return 0 }
        return min(max(playback.currentTime / playback.duration, 0), 1)
    }

    private func updateFill() {
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * fraction, height: track.bounds.height)
    }

    private func updateTimes() {
        guard let playback else { return }
        currentLabel.text = Self.format(playback.currentTime, hundredths: true)
        remainingLabel.text = Self.format(max(playback.duration - playback.currentTime, 0), hundredths: false)
    }

    @objc private func playTapped() {
        playback?.togglePlay()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @objc private func muteTapped() {
        guard let playback else { return }
        playback.isMuted.toggle()
        refresh()
    }

    @objc private func scrubbed(_ gesture: UILongPressGestureRecognizer) {
        guard let playback else { return }
        let x = gesture.location(in: self).x
        let value = Double(min(max((x - track.frame.minX) / max(track.frame.width, 1), 0), 1))
        switch gesture.state {
        case .began:
            wasPlayingBeforeScrub = playback.isPlaying
            playback.pause()
            setScrubbing(true)
            fallthrough
        case .changed:
            playback.seek(toFraction: value, precise: false)
            updateTimes()
            updateFill()
        default:
            playback.seek(toFraction: value, precise: true)
            if wasPlayingBeforeScrub { playback.play() }
            setScrubbing(false)
        }
    }

    private func setScrubbing(_ scrubbing: Bool) {
        guard scrubbing != isScrubbing else { return }
        isScrubbing = scrubbing
        if scrubbing { updateTimes() }
        UISelectionFeedbackGenerator().selectionChanged()
        onScrubbingChanged?(scrubbing)
        UIView.animate(springDuration: 0.3, bounce: 0.15) {
            self.playButton.alpha = scrubbing ? 0 : 1
            self.muteButton.alpha = scrubbing ? 0 : 1
            self.currentLabel.alpha = scrubbing ? 1 : 0
            self.remainingLabel.alpha = scrubbing ? 1 : 0
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    override func accessibilityIncrement() { playback?.seek(toFraction: fraction + 0.1, precise: true) }
    override func accessibilityDecrement() { playback?.seek(toFraction: fraction - 0.1, precise: true) }

    /// "00:04.01" (with hundredths, while scrubbing) or "00:03"; hours when needed.
    static func format(_ seconds: Double, hundredths: Bool) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let whole = Int(seconds)
        let base = whole >= 3600
            ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
            : String(format: "%02d:%02d", whole / 60, whole % 60)
        guard hundredths else { return base }
        return base + String(format: ".%02d", Int((seconds - Double(whole)) * 100))
    }

    static func format(_ seconds: Double) -> String { format(seconds, hundredths: false) }
}

extension VideoControlsView: UIGestureRecognizerDelegate {
    /// Taps on the play and mute buttons stay buttons; the rest of the capsule scrubs.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let point = gestureRecognizer.location(in: self)
        if isScrubbing { return true }
        return !playButton.frame.contains(point) && !muteButton.frame.contains(point) && background.frame.contains(point)
    }
}
