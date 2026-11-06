import UIKit
import VisionKit

/// Long-press features on a photo, from VisionKit (on-device, Neural Engine):
/// lift the subject (people, pets, objects) out of the background to copy, share or make a
/// sticker; select text (Live Text); and Visual Look Up. Analysis runs once the page settles.
@MainActor
final class SubjectLift {
    private static let analyzer = ImageAnalyzer()
    private let interaction = ImageAnalysisInteraction()
    private var task: Task<Void, Never>?
    private var analysedImage: UIImage?

    static var isSupported: Bool { ImageAnalyzer.isSupported }

    func attach(to imageView: UIImageView) {
        guard Self.isSupported, interaction.view == nil else { return }
        imageView.isUserInteractionEnabled = true
        interaction.preferredInteractionTypes = .automatic
        // The Live Text button isn't shown until the user asks; keep the photo clean.
        interaction.allowLongPressForDataDetectorsInTextMode = true
        imageView.addInteraction(interaction)
    }

    /// Analyses what the page shows now (skipped if it's the same image as last time).
    func analyse(_ image: UIImage?) {
        guard Self.isSupported, let image, image !== analysedImage else { return }
        analysedImage = image
        task?.cancel()
        interaction.analysis = nil
        task = Task { [interaction] in
            let configuration = ImageAnalyzer.Configuration([.text, .visualLookUp, .machineReadableCode])
            guard let analysis = try? await Self.analyzer.analyze(image, configuration: configuration), !Task.isCancelled else { return }
            interaction.analysis = analysis
        }
    }

    func reset() {
        task?.cancel()
        analysedImage = nil
        interaction.analysis = nil
    }

    /// Live Photos use the long press to play; subject lift stays off for them.
    func setEnabled(_ enabled: Bool) {
        interaction.preferredInteractionTypes = enabled ? .automatic : []
    }
}
