import AVFoundation
import CoreImage
import ImageIO
import Persistence
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Development aid: `-VideoEditSelfTest [-VideoEditTarget IMG_1234.MOV]`.
/// Duplicates the video (the newest phone video if no name is given) and works only on the copy:
/// every tool in the editor, with the frame the preview player really shows compared against the
/// edit rendered straight from the source; the files a save writes for geometry edits; one real
/// save through Done (iOS asks to allow it); then the copy is deleted (iOS asks again).
/// Backup is paused while the test runs. Results and frames go to Library/Caches/selftest.
@MainActor
enum VideoEditSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-VideoEditSelfTest") }

    private static var target: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-VideoEditTarget"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func say(_ text: String) {
        FileHandle.standardError.write(Data(("VIDEOTEST " + text + "\n").utf8))
        ScreenCapture.log(text)
    }

    static func run(session: LibrarySession) async {
        ScreenCapture.reset()
        let wasPaused = session.backupSettings.isPaused
        session.backupSettings.isPaused = true
        say("backup paused (was \(wasPaused))")
        defer { say("done") }

        guard let originalID = VideoTestPhotoKit.find(named: target) else { return say("video \(target ?? "(newest)") not found") }
        say("original \(VideoTestPhotoKit.describe(originalID))")
        if ProcessInfo.processInfo.arguments.contains("-VideoEditPreviewOnly") {
            // Read-only: the preview checks on the original itself; nothing is saved.
            await editorTests(originalID, session: session)
            session.backupSettings.isPaused = wasPaused
            return say("preview only; backup pause restored to \(wasPaused)")
        }
        let copyID: String
        do {
            copyID = try await VideoTestPhotoKit.duplicate(originalID)
        } catch {
            return say("duplicate failed: \(error)")
        }
        say("duplicate \(VideoTestPhotoKit.describe(copyID))")

        await editorTests(copyID, session: session)
        await fileTests(copyID)
        await realSave(copyID, session: session)

        say("deleting the duplicate (iOS asks)")
        do {
            try await PhoneLibraryChanges.delete(localIDs: [copyID])
            say("duplicate deleted: \(PHAsset.fetchAssets(withLocalIdentifiers: [copyID], options: nil).count == 0)")
            session.backupSettings.isPaused = wasPaused
            say("backup pause restored to \(wasPaused)")
        } catch {
            say("duplicate NOT deleted (\(error)); backup stays paused so its edit isn't uploaded")
        }
    }

    // MARK: Editor and preview

    private static var model: EditorModel?
    private static var host: UIViewController?
    private static var output: AVPlayerItemVideoOutput?
    private static var source: AVAsset?

    private static func item(for localID: String) -> TimelineItem? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return nil }
        return TimelineItem(
            id: "local-\(localID)", date: asset.creationDate ?? .now, isVideo: true, durationMs: Int(asset.duration * 1000),
            isFavorite: false, isLivePhoto: false, thumbhash: nil,
            aspectRatio: Double(asset.pixelWidth) / Double(max(asset.pixelHeight, 1)), hasCamera: true, localID: localID, isRemote: false
        )
    }

    private static func open(_ localID: String, session: LibrarySession) async -> UIWindow? {
        guard let item = item(for: localID),
              let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              var top = window.rootViewController else { say("no window or item"); return nil }
        await close()
        while let presented = top.presentedViewController { top = presented }
        let model = EditorModel(item: item, session: session)
        let host = UIHostingController(rootView: EditorView(model: model) { _ in })
        host.modalPresentationStyle = .fullScreen
        top.present(host, animated: false)
        let start = Date()
        while model.isLoading, Date().timeIntervalSince(start) < 120 { try? await Task.sleep(for: .milliseconds(100)) }
        say("editor loaded in \(Int(Date().timeIntervalSince(start) * 1000)) ms: duration \(String(format: "%.2f", model.duration)) s, video size \(model.videoSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? "?"), tools \(model.tools.map(\.rawValue)), stored edit \(!model.state.isIdentity)")
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        model.player.currentItem?.add(output)
        self.model = model
        self.host = host
        self.output = output
        try? await Task.sleep(for: .seconds(1.5))
        return window
    }

    private static func close() async {
        guard let host else { return }
        await withCheckedContinuation { continuation in host.dismiss(animated: false) { continuation.resume() } }
        self.host = nil
        model = nil
        output = nil
    }

    private static func editorTests(_ localID: String, session: LibrarySession) async {
        guard let window = await open(localID, session: session), let model else { return }
        source = await VideoTestPhotoKit.avAsset(localID)
        guard source != nil else { return say("no source asset") }
        var auto: AutoAdjust?
        if let source { auto = await AutoAdjust.from(source) }
        let base = await check("00-original", EditState(), model: model, auto: auto)
        ScreenCapture.snapshot(window, name: "ui-00-video")

        // Geometry: the cases that showed green or ghost areas.
        var cases: [(String, (inout EditState) -> Void)] = [
            ("g-rotate-90", { $0.quarterTurns = 1 }),
            ("g-rotate-180", { $0.quarterTurns = 2 }),
            ("g-rotate-270", { $0.quarterTurns = 3 }),
            ("g-flip", { $0.flipped = true }),
            ("g-straighten+10", { $0.straighten = 10 }),
            ("g-straighten-10", { $0.straighten = -10 }),
            ("g-vertical+", { $0.vertical = 0.5 }),
            ("g-horizontal-", { $0.horizontal = -0.5 }),
            ("g-crop-free", { $0.crop = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5) }),
            ("g-rotate-90+flip", { $0.quarterTurns = 1; $0.flipped = true }),
            ("g-rotate-90+crop-free", { $0.quarterTurns = 1; $0.crop = CGRect(x: 0.05, y: 0.3, width: 0.7, height: 0.4) }),
            ("g-rotate-270+straighten+crop", { $0.quarterTurns = 3; $0.straighten = -6; $0.crop = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8) }),
        ]
        for aspect in CropAspect.allCases where aspect != .original {
            cases.append(("g-aspect-\(aspect.rawValue)", { state in state.crop = aspect.rect(for: EditRenderer.outputSize(of: model.videoSize ?? .zero, state: state)) }))
            cases.append(("g-rotate-90+aspect-\(aspect.rawValue)", { state in
                state.quarterTurns = 1
                state.crop = aspect.rect(for: EditRenderer.outputSize(of: model.videoSize ?? .zero, state: state))
            }))
        }
        model.tool = .adjust
        for (name, edit) in cases {
            var state = EditState()
            edit(&state)
            _ = await check(name, state, model: model, auto: auto, base: base)
        }

        // Crop tool on screen: the frame over the picture, turned and not.
        model.tool = .crop
        var turned = EditState()
        turned.quarterTurns = 1
        turned.crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6)
        for (name, state) in [("ui-crop", EditState()), ("ui-crop-turned", turned)] {
            await set(state, model: model)
            try? await Task.sleep(for: .seconds(1))
            say("\(name): crop base \(dims(model.cropBaseSize)), preview aspect \(String(format: "%.3f", model.videoAspect ?? 0)), render \(dims(model.player.currentItem?.videoComposition?.renderSize ?? .zero))")
            ScreenCapture.snapshot(window, name: name)
        }
        model.tool = .adjust

        // Every adjustment both ways, Auto, and every filter.
        _ = await check("auto", { var s = EditState(); s.auto = true; return s }(), model: model, auto: auto, base: base)
        for adjustment in EditState.Adjustment.allCases {
            for value in [0.6, -0.6] {
                var state = EditState()
                state.adjustments[adjustment] = value
                _ = await check("a-\(adjustment.rawValue)\(value > 0 ? "+" : "-")", state, model: model, auto: auto, base: base)
            }
        }
        model.tool = .filters
        for filter in EditState.Filter.allCases where filter != .original {
            var state = EditState()
            state.filter = filter
            _ = await check("f-\(filter.rawValue)", state, model: model, auto: auto, base: base)
        }
        ScreenCapture.snapshot(window, name: "ui-filters")

        // Video tab: trim, mute; Audio Mix.
        model.tool = .video
        var trim = EditState()
        trim.trimStart = 2
        trim.trimEnd = min(model.duration - 2, 12)
        trim.muted = true
        await set(trim, model: model)
        try? await Task.sleep(for: .seconds(1))
        say("trim+mute: state \(String(format: "%.1f–%.1f", model.state.trimStart, model.state.trimEnd ?? -1)), player muted \(model.player.isMuted), composition \(model.player.currentItem?.videoComposition != nil)")
        ScreenCapture.snapshot(window, name: "ui-video-trim")
        if model.tools.contains(.audioMix) {
            model.tool = .audioMix
            for mix in EditState.AudioMix.allCases {
                var state = EditState()
                state.audioMix = mix
                await set(state, model: model)
                try? await Task.sleep(for: .milliseconds(500))
                say("audio mix \(mix.rawValue): player audioMix set \(model.player.currentItem?.audioMix != nil)")
            }
            ScreenCapture.snapshot(window, name: "ui-audiomix")
        } else {
            say("audio mix: not offered for this video")
        }

        // Undo / redo across a turn.
        await set(EditState(), model: model)
        model.beginChange(); model.state.quarterTurns = 1
        model.beginChange(); model.state.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        model.undo()
        say("undo: turns \(model.state.quarterTurns) crop full \(model.state.crop == CGRect(x: 0, y: 0, width: 1, height: 1))")
        model.redo()
        say("redo: crop \(model.state.crop)")
        await close()
    }

    private static func set(_ state: EditState, model: EditorModel) async {
        model.beginChange()
        model.state = state
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Applies `state`, waits for the preview's composition, and compares the frame the player
    /// produces with the edit rendered straight from the source frame.
    @discardableResult
    private static func check(_ name: String, _ state: EditState, model: EditorModel, auto: AutoAdjust?, base: ImageStats? = nil) async -> ImageStats? {
        let previous = model.player.currentItem?.videoComposition
        await set(state, model: model)
        let start = Date()
        if state.hasVisualChanges {
            while model.player.currentItem?.videoComposition === previous || model.player.currentItem?.videoComposition == nil {
                if Date().timeIntervalSince(start) > 6 { say("\(name): composition not updated"); break }
                try? await Task.sleep(for: .milliseconds(30))
            }
        } else {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let size = model.videoSize, let source, let output, let item = model.player.currentItem else { return nil }
        let expected = state.hasVisualChanges ? EditRenderer.videoRenderSize(upright: size, state: state) : size
        // The player applies a new composition a moment after it's set: a frame can still come
        // from the previous edit. Seek again until the frame matches its own time and edit.
        var best: (frame: CGImage, buffer: CVPixelBuffer, reference: CGImage?, difference: Double)?
        var attempts = 0
        for attempt in 1...5 {
            attempts = attempt
            let time = CMTime(seconds: min(3, model.duration / 2) + Double(attempt) * 0.1, preferredTimescale: 600)
            await model.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            try? await Task.sleep(for: .milliseconds(attempt == 1 ? 150 : 400))
            var buffer: CVPixelBuffer?
            var shownTime = CMTime.invalid
            let grabStart = Date()
            while buffer == nil, Date().timeIntervalSince(grabStart) < 3 {
                let now = item.currentTime()
                if output.hasNewPixelBuffer(forItemTime: now) { buffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &shownTime) }
                if buffer == nil { try? await Task.sleep(for: .milliseconds(40)) }
            }
            guard let buffer else { continue }
            let shown = CIImage(cvPixelBuffer: buffer)
            guard let frame = FrameMath.context.createCGImage(shown, from: shown.extent) else { continue }
            let reference = await FrameMath.reference(source, at: shownTime.isValid ? shownTime : time, state: state, renderSize: expected, auto: auto)
            let difference = reference.map { FrameMath.difference(frame, $0) } ?? 1
            if best == nil || difference < best!.difference { best = (frame, buffer, reference, difference) }
            if difference < 0.07 { break }
        }
        guard let best else { say("\(name): no frame from the player"); return nil }
        let stats = ImageStats(UIImage(cgImage: best.frame))
        let width = CVPixelBufferGetWidth(best.buffer), height = CVPixelBufferGetHeight(best.buffer)
        var line = "\(name): frame \(width)×\(height) expected \(dims(expected))"
        line += width == Int(expected.width) && height == Int(expected.height) ? " OK" : " SIZE MISMATCH"
        line += String(format: ", green area %.3f", FrameMath.greenArea(best.frame))
        if let reference = best.reference {
            line += String(format: " (reference %.3f), difference from reference %.3f%@", FrameMath.greenArea(reference), best.difference, best.difference < 0.07 ? "" : " DIFFERS")
            FrameMath.saveSideBySide(best.frame, reference, name: "v-\(name)", in: ScreenCapture.folder)
        }
        line += ", attempts \(attempts)"
        if let base { line += " | " + stats.delta(from: base) }
        say(line)
        return stats
    }

    // MARK: Files a save writes

    private static func fileTests(_ localID: String) async {
        var states: [(String, EditState)] = []
        var trim = EditState(); trim.trimStart = 1; trim.trimEnd = 4
        states.append(("trim", trim))
        var turn = trim; turn.quarterTurns = 1
        states.append(("rotate-90", turn))
        var square = trim; square.crop = CropAspect.square.rect(for: CGSize(width: 16, height: 9))
        states.append(("crop-square", square))
        var mixed = trim
        mixed.quarterTurns = 3; mixed.straighten = 5; mixed.crop = CGRect(x: 0.1, y: 0.15, width: 0.7, height: 0.6)
        mixed.adjustments[.exposure] = 0.3; mixed.filter = .vivid
        states.append(("rotate-270-straighten-crop-vivid", mixed))
        var flip = trim; flip.flipped = true; flip.auto = true
        states.append(("flip-auto", flip))
        for line in await VideoTestPhotoKit.renderFiles(localID, states: states, folder: ScreenCapture.folder) { say(line) }
    }

    // MARK: Real save

    private static func realSave(_ localID: String, session: LibrarySession) async {
        guard let window = await open(localID, session: session), let model else { return }
        var state = EditState()
        state.trimStart = 1; state.trimEnd = 6
        state.quarterTurns = 1
        state.crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7)
        state.adjustments[.exposure] = 0.25
        await set(state, model: model)
        try? await Task.sleep(for: .seconds(1))
        say("saving through Done (iOS asks to allow it)")
        let start = Date()
        let saved = await model.save()
        say("save \(saved) in \(Int(Date().timeIntervalSince(start) * 1000)) ms\(model.errorMessage.map { ", error: \($0)" } ?? "")")
        await close()
        for line in await VideoTestPhotoKit.inspectSaved(localID, expected: state, folder: ScreenCapture.folder) { say(line) }
        // Reopening shows the stored edit on the original.
        if let window2 = await open(localID, session: session), let reopened = self.model {
            say("reopened: stored edit restored \(reopened.state == state)")
            ScreenCapture.snapshot(window2, name: "ui-reopened")
            await close()
        }
        _ = window
    }

    private static func dims(_ size: CGSize) -> String { "\(Int(size.width))×\(Int(size.height))" }
}

/// Frame comparisons for the video test.
enum FrameMath {
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// The edit applied straight to the source frame at `time` (what the preview should show).
    nonisolated(nonsending) static func reference(_ asset: AVAsset, at time: CMTime, state: EditState, renderSize: CGSize, auto: AutoAdjust?) async -> CGImage? {
        guard let frame = await VideoComposer.frame(AssetBox(asset: asset), at: time) else { return nil }
        let image = state.hasVisualChanges
            ? EditRenderer.videoFrame(state, source: CIImage(cgImage: frame), renderSize: renderSize, autoFilters: state.auto ? auto?.makeFilters() ?? [] : [])
            : CIImage(cgImage: frame)
        return context.createCGImage(image, from: CGRect(origin: .zero, size: image.extent.size))
    }

    /// Share of pixels that are clearly green (where empty video buffers show).
    static func greenArea(_ image: CGImage) -> Double {
        let (pixels, w, h) = small(image, width: 96, height: 96)
        var count = 0
        for i in 0..<(w * h) {
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
            if g - max(r, b) > 60 { count += 1 }
        }
        return Double(count) / Double(w * h)
    }

    /// Mean absolute difference (0–1) between two frames scaled to the same small size.
    static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let (pa, w, h) = small(a, width: 64, height: 64)
        let (pb, _, _) = small(b, width: 64, height: 64)
        var sum = 0
        for i in 0..<(w * h) { for c in 0..<3 { sum += abs(Int(pa[i * 4 + c]) - Int(pb[i * 4 + c])) } }
        return Double(sum) / Double(w * h * 3 * 255)
    }

    private static func small(_ image: CGImage, width: Int, height: Int) -> ([UInt8], Int, Int) {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        if let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (pixels, width, height)
    }

    /// Player frame on the left, reference on the right, each at most 480 pixels high.
    static func saveSideBySide(_ shown: CGImage, _ reference: CGImage, name: String, in folder: URL) {
        let scale = 480 / Double(max(shown.height, reference.height))
        let w1 = Int(Double(shown.width) * scale), w2 = Int(Double(reference.width) * scale), h = 480
        guard let context = CGContext(data: nil, width: w1 + w2 + 12, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(UIColor.magenta.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: w1 + w2 + 12, height: h))
        context.draw(shown, in: CGRect(x: 0, y: 0, width: w1, height: Int(Double(shown.height) * scale)))
        context.draw(reference, in: CGRect(x: w1 + 12, y: 0, width: w2, height: Int(Double(reference.height) * scale)))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(folder.appending(path: "\(name).jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}

/// PhotoKit and file work for the video test, off the main actor (PhotoKit calls back on its own queues).
enum VideoTestPhotoKit {
    static func find(named name: String?) -> String? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let videos = PHAsset.fetchAssets(with: .video, options: options)
        guard let name else { return videos.firstObject?.localIdentifier }
        var found: String?
        videos.enumerateObjects { asset, _, stop in
            let resources = PHAssetResource.assetResources(for: asset)
            if resources.contains(where: { $0.type == .video && $0.originalFilename.caseInsensitiveCompare(name) == .orderedSame }) {
                found = asset.localIdentifier
                stop.pointee = true
            }
        }
        return found
    }

    static func describe(_ localID: String) -> String {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return "gone" }
        let resources = PHAssetResource.assetResources(for: asset)
        let video = resources.first { $0.type == .video }
        let bytes = (video?.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
        return "\(video?.originalFilename ?? "?") \(asset.pixelWidth)×\(asset.pixelHeight) \(String(format: "%.1f", asset.duration)) s \(bytes / 1_048_576) MB, created \(asset.creationDate?.description ?? "?"), resources \(resources.map { $0.type.rawValue })"
    }

    /// A new library item from the original's file, with the same date and place.
    static func duplicate(_ localID: String) async throws -> String {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject,
              let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .video }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "video-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
        let box = IDBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let resourceOptions = PHAssetResourceCreationOptions()
            resourceOptions.originalFilename = resource.originalFilename
            request.addResource(with: .video, fileURL: file, options: resourceOptions)
            request.creationDate = asset.creationDate
            request.location = asset.location
            box.id = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id = box.id else { throw CocoaError(.fileWriteUnknown) }
        return id
    }

    private final class IDBox: @unchecked Sendable { var id: String? }

    static func avAsset(_ localID: String) async -> AVAsset? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return nil }
        let options = PHVideoRequestOptions()
        options.version = .original
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        let box: AssetBox = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: AssetBox(asset: avAsset))
            }
        }
        return box.asset
    }

    /// Renders each state as a save would, then reads the file back.
    static func renderFiles(_ localID: String, states: [(String, EditState)], folder: URL) async -> [String] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return ["files: asset gone"] }
        var lines: [String] = []
        do {
            let input = try await EditSaver.contentEditingInput(for: asset)
            guard let source = input.audiovisualAsset else { return ["files: no AV asset"] }
            lines.append("source: " + (await describe(file: source)))
            let upright = try await VideoComposer.uprightSize(of: source) ?? .zero
            let auto = await AutoAdjust.from(source)
            for (name, state) in states {
                let url = folder.appending(path: "file-\(name).mov")
                let start = Date()
                try await EditSaver.renderVideo(source, state: state, to: url)
                let written = AVURLAsset(url: url)
                var line = "file \(name): \(Int(Date().timeIntervalSince(start) * 1000)) ms, " + (await describe(file: written))
                let expected = state.hasVisualChanges ? EditRenderer.videoRenderSize(upright: upright, state: state) : upright
                let shown = try? await VideoComposer.uprightSize(of: written)
                line += ", expected \(Int(expected.width))×\(Int(expected.height))" + (shown == expected ? " OK" : " SIZE MISMATCH")
                // Frames from the written file against the edit rendered from the source.
                for offset in [0.2, 1.5, 2.8] {
                    let generator = AVAssetImageGenerator(asset: written)
                    generator.appliesPreferredTrackTransform = true
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                    guard let frame = try? await generator.image(at: CMTime(seconds: offset, preferredTimescale: 600)).image else { line += "; frame at \(offset) s missing"; continue }
                    let sourceTime = CMTime(seconds: state.trimStart + offset, preferredTimescale: 600)
                    if let reference = await FrameMath.reference(source, at: sourceTime, state: state, renderSize: expected, auto: auto) {
                        line += String(format: "; at %.1f s green %.3f diff %.3f", offset, FrameMath.greenArea(frame), FrameMath.difference(frame, reference))
                        if offset == 1.5 { FrameMath.saveSideBySide(frame, reference, name: "file-\(name)", in: folder) }
                    }
                }
                lines.append(line)
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            lines.append("files: error \(error)")
        }
        return lines
    }

    static func describe(file asset: AVAsset) async -> String {
        var parts: [String] = []
        if let duration = try? await asset.load(.duration) { parts.append(String(format: "%.2f s", duration.seconds)) }
        if let tracks = try? await asset.load(.tracks) {
            for track in tracks {
                let type = track.mediaType.rawValue
                if track.mediaType == .video,
                   let (natural, transform, formats) = try? await track.load(.naturalSize, .preferredTransform, .formatDescriptions),
                   let format = formats.first {
                    let codec = CMFormatDescriptionGetMediaSubType(format)
                    let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((codec >> $0) & 0xff) }, encoding: .ascii) ?? "?"
                    let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
                    let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? "-"
                    let depth = extensions[kCMFormatDescriptionExtension_Depth as String] as? Int ?? 0
                    let dolby = (extensions["SampleDescriptionExtensionAtoms"] as? [String: Any])?.keys.contains { $0.hasPrefix("dv") } ?? false
                    let turned = transform.b != 0 ? " turned" : ""
                    parts.append("\(type) \(fourCC) \(Int(natural.width))×\(Int(natural.height))\(turned) \(transfer) depth \(depth)\(dolby ? " DolbyVision" : "")")
                } else {
                    parts.append(type)
                }
            }
        }
        if let metadata = try? await asset.load(.metadata) { parts.append("metadata \(metadata.count)") }
        return parts.joined(separator: ", ")
    }

    /// After a real save: what PhotoKit stored.
    static func inspectSaved(_ localID: String, expected: EditState, folder: URL) async -> [String] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return ["saved: asset gone"] }
        let resources = PHAssetResource.assetResources(for: asset)
        var lines = ["saved: \(asset.pixelWidth)×\(asset.pixelHeight) \(String(format: "%.2f", asset.duration)) s, resources " + resources.map { "\($0.type.rawValue):\($0.originalFilename)" }.joined(separator: ", ")]
        lines.append("saved: stored edit matches \(await EditSaver.storedState(localID: localID) == expected)")
        if let rendered = resources.first(where: { $0.type == .fullSizeVideo }) {
            let url = folder.appending(path: "saved-edit.mov")
            try? FileManager.default.removeItem(at: url)
            do {
                try await PHAssetResourceManager.default().writeData(for: rendered, toFile: url, options: nil)
                lines.append("saved file: " + (await describe(file: AVURLAsset(url: url))))
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                if let frame = try? await generator.image(at: CMTime(seconds: 2, preferredTimescale: 600)).image {
                    lines.append(String(format: "saved file: green area %.3f", FrameMath.greenArea(frame)))
                    FrameMath.saveSideBySide(frame, frame, name: "saved-edit", in: folder)
                }
                try? FileManager.default.removeItem(at: url)
            } catch {
                lines.append("saved file: copy failed \(error)")
            }
        } else {
            lines.append("saved: no rendered video resource")
        }
        return lines
    }
}
