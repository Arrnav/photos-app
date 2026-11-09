import AVFoundation
import Persistence
import Photos
import SwiftUI
import UIKit

/// Development aid. Drives the Edit screen on a device and records what it shows.
/// - `-EditorSelfTest`: every tool and value on the newest phone photo and video, with snapshots
///   and measurements of the preview (Library/Caches/selftest), and the files a save would
///   write (rendered into the same folder, the library untouched).
/// - `-EditorSaveSelfTest`: saves one edit to the newest phone photo through Done (iOS asks to
///   allow it), then checks what PhotoKit stored.
/// - `-EditorRevertSelfTest`: Revert to Original + Done on the newest phone photo (iOS asks).
@MainActor
enum EditorSelfTest {
    static var isEnabled: Bool { mode != nil }

    static var mode: String? {
        let arguments = ProcessInfo.processInfo.arguments
        return ["-EditorSelfTest", "-EditorFilesSelfTest", "-EditorSaveSelfTest", "-EditorRevertSelfTest"].first { arguments.contains($0) }
    }

    static func say(_ text: String) {
        FileHandle.standardError.write(Data(("EDITORTEST " + text + "\n").utf8))
        ScreenCapture.log(text)
    }

    static func run(session: LibrarySession) async {
        ScreenCapture.reset()
        let items = session.timeline.items
        guard let photo = items.last(where: { !$0.isVideo && $0.localID != nil }) else { return say("no phone photo") }
        say("photo \(photo.id.prefix(8)) live \(photo.isLivePhoto) edited \(photo.isEdited) aspect \(String(format: "%.3f", photo.aspectRatio))")
        switch mode {
        case "-EditorSaveSelfTest": await saveTest(photo, session: session)
        case "-EditorRevertSelfTest": await revertTest(photo, session: session)
        case "-EditorFilesSelfTest":
            // Camera originals: an HDR video and a Live Photo, rendered as a save would (library untouched).
            if let video = items.last(where: { $0.isVideo && $0.localID != nil && $0.hasCamera && !$0.isEdited }), let localID = video.localID {
                say("camera video \(video.id.prefix(8)) \(video.durationMs ?? 0) ms")
                var trim = EditState()
                trim.trimStart = 0.5
                trim.trimEnd = min(3.5, Double(video.durationMs ?? 4000) / 1000)
                var visual = trim
                visual.adjustments[.exposure] = 0.3
                visual.filter = .vivid
                for line in await PhoneEditFiles.renderVideo(localID: localID, trim: trim, visual: visual, folder: ScreenCapture.folder) { say(line) }
            }
            if let liveID = PhoneEditFiles.newestLivePhoto() {
                say("live photo \(liveID.prefix(8)), in Library list \(items.contains { $0.localID == liveID })")
                var look = EditState()
                look.adjustments[.exposure] = 0.3
                look.filter = .vivid
                for line in await PhoneEditFiles.render(localID: liveID, state: look, folder: ScreenCapture.folder) { say(line) }
            } else {
                say("no Live Photo on this iPhone")
            }
        default:
            await photoTest(photo, session: session)
            if let video = items.last(where: { $0.isVideo && $0.localID != nil }) {
                await videoTest(video, session: session)
            } else {
                say("no phone video")
            }
            if let cloud = items.last(where: { !$0.isVideo && $0.localID == nil && $0.isRemote }) {
                await cloudRenderTest(cloud, session: session)
            }
        }
        await closeAll()
        say("done")
    }

    // MARK: Photo: every control

    private static func photoTest(_ item: TimelineItem, session: LibrarySession) async {
        guard let (model, host, window) = await present(item, session: session) else { return }
        defer { closing.append(host) }
        guard let first = model.preview else { return say("photo: no preview, error \(model.errorMessage ?? "-")") }
        let base = ImageStats(first)
        say("photo preview \(Int(first.size.width))×\(Int(first.size.height)); tools \(model.tools.map(\.rawValue)); base \(base)")
        snap(window, "p00-adjust")

        await change(model) { $0.auto = true }
        report("auto", base, model, window)
        await change(model) { $0.auto = false }

        for adjustment in EditState.Adjustment.allCases {
            model.selection = .adjustment(adjustment)
            for value in adjustment.allowsNegative ? [0.8, -0.8] : [0.8] {
                await change(model) { $0.adjustments[adjustment] = value }
                report("\(adjustment.rawValue)\(value > 0 ? "+" : "-")", base, model, window)
            }
            await change(model) { $0.adjustments[adjustment] = nil }
        }
        model.selection = .auto

        model.tool = .filters
        try? await Task.sleep(for: .seconds(1))
        say("filter thumbnails \(model.filterThumbnails.count)/\(EditState.Filter.allCases.count)")
        for filter in EditState.Filter.allCases where filter != .original {
            await change(model) { $0.filter = filter }
            report("filter-\(filter.rawValue)", base, model, window)
        }
        await change(model) { $0.filter = .original }

        // Undo / redo
        await change(model) { $0.adjustments[.exposure] = 0.5 }
        await change(model) { $0.filter = .mono }
        model.undo(); try? await Task.sleep(for: .milliseconds(400))
        say("undo → filter \(model.state.filter.rawValue), exposure \(model.state.value(.exposure)) (expect original, 0.5)")
        model.redo(); try? await Task.sleep(for: .milliseconds(400))
        say("redo → filter \(model.state.filter.rawValue) (expect mono)")
        model.revertToOriginal(); try? await Task.sleep(for: .milliseconds(400))
        say("revert → identity \(model.state.isIdentity), Done enabled \(model.hasChanges) (expect true, false for an unedited photo)")

        // Crop
        model.tool = .crop
        try? await Task.sleep(for: .seconds(1))
        snap(window, "p50-crop")
        for (name, edit) in [
            ("straighten+10", { (s: inout EditState) in s.straighten = 10 }),
            ("vertical+0.6", { (s: inout EditState) in s.straighten = 0; s.vertical = 0.6 }),
            ("horizontal+0.6", { (s: inout EditState) in s.vertical = 0; s.horizontal = 0.6 }),
        ] {
            await change(model, edit)
            report("crop-\(name)", base, model, window)
        }
        await change(model) { $0.horizontal = 0 }
        let size = model.preview?.size ?? .zero
        await change(model) { $0.crop = CropAspect.square.rect(for: size) }
        snap(window, "p54-crop-square-frame")
        model.tool = .adjust
        try? await Task.sleep(for: .seconds(1))
        let cropped = model.preview?.size ?? .zero
        say("square crop → \(Int(cropped.width))×\(Int(cropped.height)) (expect equal sides)")
        snap(window, "p55-crop-square-applied")
        await change(model) { $0.crop = CGRect(x: 0, y: 0, width: 1, height: 1); $0.quarterTurns = 1 }
        let turned = model.preview?.size ?? .zero
        say("rotate → \(Int(turned.width))×\(Int(turned.height)) (was \(Int(first.size.width))×\(Int(first.size.height)); expect swapped)")
        snap(window, "p56-rotated")
        await change(model) { $0.quarterTurns = 0; $0.flipped = true }
        if let flipped = model.preview { say("flip → left/right luma \(ImageStats(flipped).halves) (base \(base.halves); expect swapped)") }
        snap(window, "p57-flipped")
        await change(model) { $0 = EditState() }

        // What Done would write, without touching the library.
        var look = EditState()
        look.adjustments[.exposure] = 0.3
        look.filter = .vivid
        look.crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        await renderPhoneFiles(item, state: look)
    }

    private static func renderPhoneFiles(_ item: TimelineItem, state: EditState) async {
        guard let localID = item.localID else { return }
        let result = await PhoneEditFiles.render(localID: localID, state: state, folder: ScreenCapture.folder)
        for line in result { say(line) }
    }

    // MARK: Video

    private static func videoTest(_ item: TimelineItem, session: LibrarySession) async {
        say("video \(item.id.prefix(8)) \(item.durationMs ?? 0) ms")
        guard let (model, host, window) = await present(item, session: session) else { return }
        defer { closing.append(host) }
        say("video duration \(String(format: "%.2f", model.duration)) s, frames \(model.frames.count), tools \(model.tools.map(\.rawValue)), filter thumbnails \(model.filterThumbnails.count)")
        snap(window, "v00-video")
        let duration = model.duration
        await change(model) { $0.trimStart = min(1, duration / 4); $0.trimEnd = max(duration - 1, duration * 3 / 4) }
        snap(window, "v01-trimmed")
        await change(model) { $0.muted = true }
        say("muted → player muted \(model.player.isMuted)")
        snap(window, "v02-muted")
        if model.tools.contains(.audioMix) {
            model.tool = .audioMix
            await change(model) { $0.audioMix = .cinematic }
            say("audio mix → \(model.state.audioMix.rawValue), player audioMix set \(model.player.currentItem?.audioMix != nil)")
            snap(window, "v03-audiomix")
        } else {
            say("audio mix: not offered (no spatial audio in this video)")
        }
        model.tool = .adjust
        model.selection = .adjustment(.exposure)
        await change(model) { $0.adjustments[.exposure] = 0.6 }
        try? await Task.sleep(for: .seconds(1))
        say("adjust → video composition set \(model.player.currentItem?.videoComposition != nil)")
        snap(window, "v04-adjust")
        model.tool = .filters
        await change(model) { $0.filter = .noir }
        snap(window, "v05-filters")
        model.tool = .crop
        try? await Task.sleep(for: .seconds(1))
        snap(window, "v06-crop")

        guard let localID = item.localID, duration > 2 else { return say("video: no duration, files skipped") }
        var trim = EditState()
        trim.trimStart = min(1, duration / 4)
        trim.trimEnd = min(trim.trimStart + 3, duration)
        var visual = trim
        visual.adjustments[.exposure] = 0.3
        visual.filter = .vivid
        visual.quarterTurns = 1
        for line in await PhoneEditFiles.renderVideo(localID: localID, trim: trim, visual: visual, folder: ScreenCapture.folder) { say(line) }
    }

    // MARK: Cloud-only

    private static func cloudRenderTest(_ item: TimelineItem, session: LibrarySession) async {
        guard session.connection != nil else { return say("cloud: not connected, skipped") }
        let name = session.detailsNow(for: item.id)?.asset.originalFileName ?? "Photo.HEIC"
        do {
            let original = try await session.originals.file(assetID: item.id, fileName: name)
            var look = EditState()
            look.filter = .dramatic
            look.quarterTurns = 1
            let folder = ScreenCapture.folder
            let ext = (name as NSString).pathExtension
            try? FileManager.default.copyItem(at: original, to: folder.appending(path: "cloud-original.\(ext)"))
            try await Task.detached { try EditSaver.renderPhoto(from: original, state: look, to: folder.appending(path: "cloud-edited.HEIC")) }.value
            say("cloud: rendered \(name)")
        } catch {
            say("cloud: \(error)")
        }
    }

    // MARK: Save / revert through the screen (iOS asks to allow the change)

    private static func saveTest(_ item: TimelineItem, session: LibrarySession) async {
        guard let (model, host, window) = await present(item, session: session) else { return }
        defer { closing.append(host) }
        await change(model) { $0.adjustments[.exposure] = 0.3; $0.filter = .vivid; $0.crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8) }
        snap(window, "s00-before-done")
        say("saving (iOS asks to allow the change)")
        let saved = await model.save()
        say("save → \(saved), error \(model.errorMessage ?? "-")")
        guard saved, let localID = item.localID else { return }
        for line in await PhoneEditFiles.inspectSaved(localID: localID, folder: ScreenCapture.folder) { say(line) }
        // Reopening continues from the original with the stored values.
        let reopened = EditorModel(item: item, session: session)
        await reopened.load()
        say("reopen → stored state equal \(reopened.state == model.state), edited \(reopened.isEdited)")
    }

    /// Library tiles taken within a minute of `item` (one photo and its versions → one tile).
    private static func tilesNear(_ item: TimelineItem, session: LibrarySession) -> String {
        let near = session.timeline.items.filter { abs($0.date.timeIntervalSince(item.date)) < 60 }
        return "\(near.count) tile(s) \(near.map { "\($0.id.prefix(8)) local \($0.localID != nil) edited \($0.isEdited)" })"
    }

    private static func revertTest(_ item: TimelineItem, session: LibrarySession) async {
        try? await Task.sleep(for: .seconds(6))
        say("library before: \(tilesNear(item, session: session))")
        if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first { snap(window, "r00-library") }
        guard let (model, host, _) = await present(item, session: session) else { return }
        defer { closing.append(host) }
        say("before revert: edited \(model.isEdited)")
        model.revertToOriginal()
        say("reverting (iOS asks to allow the change)")
        let saved = await model.save()
        say("revert → \(saved), error \(model.errorMessage ?? "-")")
        guard let localID = item.localID else { return }
        for line in await PhoneEditFiles.inspectSaved(localID: localID, folder: ScreenCapture.folder) { say(line) }
        await closeAll()
        try? await Task.sleep(for: .seconds(15))
        say("library after: \(tilesNear(item, session: session))")
        if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first { snap(window, "r01-library") }
    }

    // MARK: Helpers

    /// Editors to close before the next one opens.
    private static var closing: [UIViewController] = []

    private static func closeAll() async {
        for host in closing {
            await withCheckedContinuation { continuation in
                host.dismiss(animated: false) { continuation.resume() }
            }
        }
        closing.removeAll()
    }

    private static func present(_ item: TimelineItem, session: LibrarySession) async -> (EditorModel, UIViewController, UIWindow)? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              var top = window.rootViewController else { say("no window"); return nil }
        await closeAll()
        try? await Task.sleep(for: .seconds(1))
        while let presented = top.presentedViewController { top = presented }
        say("presenting from \(type(of: top))")
        let model = EditorModel(item: item, session: session)
        let host = UIHostingController(rootView: EditorView(model: model) { _ in })
        host.modalPresentationStyle = .fullScreen
        top.present(host, animated: false)
        let start = Date()
        while model.isLoading || (model.preview == nil && !item.isVideo && model.errorMessage == nil) {
            if Date().timeIntervalSince(start) > 120 { say("editor still loading after 120 s"); break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        say("editor shown \(host.presentingViewController != nil), loaded in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        try? await Task.sleep(for: .seconds(1.5))
        return (model, host, window)
    }

    /// Applies a change as a tap would (Undo records it) and waits for the preview to update.
    private static func change(_ model: EditorModel, _ edit: (inout EditState) -> Void) async {
        let before = model.preview
        model.beginChange()
        var state = model.state
        edit(&state)
        model.state = state
        let start = Date()
        while !model.item.isVideo, model.preview === before, Date().timeIntervalSince(start) < 3 {
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(model.item.isVideo ? 700 : 250))
    }

    private static func report(_ name: String, _ base: ImageStats, _ model: EditorModel, _ window: UIWindow) {
        guard let image = model.preview else { return say("\(name): no preview") }
        say("\(name): \(ImageStats(image).delta(from: base))")
        snap(window, "p-\(name)")
    }

    private static func snap(_ window: UIWindow, _ name: String) {
        ScreenCapture.snapshot(window, name: name)
    }
}

/// Simple measures of an image, to check that each control moves it the right way.
struct ImageStats: CustomStringConvertible {
    var luma = 0.0, p5 = 0.0, p95 = 0.0, contrast = 0.0, saturation = 0.0, warm = 0.0, green = 0.0, edges = 0.0, corners = 0.0, centre = 0.0
    var left = 0.0, right = 0.0, detail = 0.0

    init(_ image: UIImage) {
        guard let cg = image.cgImage else { return }
        detail = Self.detail(cg)
        let scale = 480 / Double(max(cg.width, cg.height))
        let w = max(Int(Double(cg.width) * scale), 1), h = max(Int(Double(cg.height) * scale), 1)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lumas = [Double](repeating: 0, count: w * h)
        var sumSat = 0.0, sumWarm = 0.0, sumGreen = 0.0, sumL = 0.0, sumLeft = 0.0, sumRight = 0.0
        var cornerSum = 0.0, cornerN = 0.0, centreSum = 0.0, centreN = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                lumas[y * w + x] = l
                sumL += l
                sumSat += max(r, g, b) - min(r, g, b)
                sumWarm += r - b
                sumGreen += g - (r + b) / 2
                if x < w / 2 { sumLeft += l } else { sumRight += l }
                let fx = Double(x) / Double(w), fy = Double(y) / Double(h)
                if (fx < 0.12 || fx > 0.88) && (fy < 0.12 || fy > 0.88) { cornerSum += l; cornerN += 1 }
                if abs(fx - 0.5) < 0.15 && abs(fy - 0.5) < 0.15 { centreSum += l; centreN += 1 }
            }
        }
        let n = Double(w * h)
        luma = sumL / n
        saturation = sumSat / n
        warm = sumWarm / n
        green = sumGreen / n
        left = sumLeft / (n / 2)
        right = sumRight / (n / 2)
        corners = cornerSum / max(cornerN, 1)
        centre = centreSum / max(centreN, 1)
        let sorted = lumas.sorted()
        p5 = sorted[Int(n * 0.05)]
        p95 = sorted[Int(n * 0.95)]
        contrast = (lumas.reduce(0) { $0 + ($1 - luma) * ($1 - luma) } / n).squareRoot()
        var edgeSum = 0.0
        for y in 0..<h { for x in 0..<(w - 1) { edgeSum += abs(lumas[y * w + x + 1] - lumas[y * w + x]) } }
        edges = edgeSum / Double(h * (w - 1))
    }

    /// Mean neighbour difference in a 400-pixel square at the centre, at full resolution
    /// (sharpening and noise reduction only show there).
    private static func detail(_ cg: CGImage) -> Double {
        let side = min(400, cg.width, cg.height)
        guard let crop = cg.cropping(to: CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)) else { return 0 }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum = 0.0
        for y in 0..<side {
            for x in 0..<(side - 1) {
                let i = (y * side + x) * 4
                sum += abs(Double(pixels[i + 1]) - Double(pixels[i + 5]))
            }
        }
        return sum / Double(side * (side - 1)) / 255
    }

    var halves: String { String(format: "%.3f/%.3f", left, right) }

    var description: String {
        String(format: "L %.3f p5 %.3f p95 %.3f C %.3f S %.3f warm %.3f green %.3f edge %.4f detail %.4f vign %.3f", luma, p5, p95, contrast, saturation, warm, green, edges, detail, corners / max(centre, 0.001))
    }

    func delta(from base: ImageStats) -> String {
        String(format: "ΔL %+.3f Δp5 %+.3f Δp95 %+.3f ΔC %+.3f ΔS %+.3f Δwarm %+.3f Δgreen %+.3f Δedge %+.4f Δdetail %+.4f Δvign %+.3f",
               luma - base.luma, p5 - base.p5, p95 - base.p95, contrast - base.contrast, saturation - base.saturation,
               warm - base.warm, green - base.green, edges - base.edges, detail - base.detail,
               corners / max(centre, 0.001) - base.corners / max(base.centre, 0.001))
    }
}

/// PhotoKit and AVFoundation work for the editor test, off the main actor (PhotoKit calls back
/// on its own queues).
enum PhoneEditFiles {
    /// Copies the original and writes what a save would: the still (and for a Live Photo, the
    /// pair through PhotoKit's Live Photo editing, into a scratch output).
    static func render(localID: String, state: EditState, folder: URL) async -> [String] {
        var lines: [String] = []
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return ["files: asset gone"] }
        do {
            let input = try await EditSaver.contentEditingInput(for: asset)
            if let url = input.fullSizeImageURL {
                try? FileManager.default.copyItem(at: url, to: folder.appending(path: "photo-original.\(url.pathExtension)"))
                let start = Date()
                try EditSaver.renderPhoto(from: url, state: state, to: folder.appending(path: "photo-edited.HEIC"))
                lines.append("files: still rendered in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            }
            if asset.mediaSubtypes.contains(.photoLive), let live = PHLivePhotoEditingContext(livePhotoEditingInput: input) {
                let output = PHContentEditingOutput(contentEditingInput: input)
                output.adjustmentData = PHAdjustmentData(formatIdentifier: EditSaver.formatIdentifier, formatVersion: EditSaver.formatVersion, data: try JSONEncoder().encode(state))
                live.frameProcessor = { frame, _ in EditRenderer.apply(state, to: frame.image) }
                let start = Date()
                try await live.saveLivePhoto(to: output)
                lines.append("files: Live Photo pair rendered in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                let scratch = (try? output.renderedContentURL(for: .heic))?.deletingLastPathComponent()
                if let scratch, let files = try? FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.fileSizeKey]) {
                    for file in files {
                        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        lines.append("files: live output \(file.lastPathComponent) \(size) bytes")
                        try? FileManager.default.copyItem(at: file, to: folder.appending(path: "live-\(file.lastPathComponent)"))
                    }
                }
                if let pairs = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .pairedVideo }) {
                    let target = folder.appending(path: "live-original.MOV")
                    try? await PHAssetResourceManager.default().writeData(for: pairs, toFile: target, options: nil)
                }
            }
        } catch {
            lines.append("files: error \(error)")
        }
        return lines
    }

    static func newestLivePhoto() -> String? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoLive.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: .image, options: options).firstObject?.localIdentifier
    }

    static func renderVideo(localID: String, trim: EditState, visual: EditState, folder: URL) async -> [String] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return ["video files: asset gone"] }
        var lines: [String] = []
        do {
            let input = try await EditSaver.contentEditingInput(for: asset)
            guard let source = input.audiovisualAsset else { return ["video files: no AV asset"] }
            if let url = (source as? AVURLAsset)?.url {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                lines.append("video files: original \(url.lastPathComponent) \(size / 1_048_576) MB")
                if size < 400_000_000 { try? FileManager.default.copyItem(at: url, to: folder.appending(path: "video-original.\(url.pathExtension)")) }
            }
            for (name, state) in [("video-trim.mov", trim), ("video-visual.mov", visual)] {
                let start = Date()
                try await EditSaver.renderVideo(source, state: state, to: folder.appending(path: name))
                lines.append("video files: \(name) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            }
        } catch {
            lines.append("video files: error \(error)")
        }
        return lines
    }

    /// After a save or revert: the asset's resources, its stored edit, and copies of the current files.
    static func inspectSaved(localID: String, folder: URL) async -> [String] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return ["saved: asset gone"] }
        let resources = PHAssetResource.assetResources(for: asset)
        var lines = ["saved: resources " + resources.map { "\($0.type.rawValue):\($0.originalFilename)" }.joined(separator: ", ")]
        lines.append("saved: stored edit \(await EditSaver.storedState(localID: localID) != nil)")
        for resource in resources where [.fullSizePhoto, .fullSizePairedVideo].contains(resource.type) {
            let target = folder.appending(path: "saved-\(resource.originalFilename)")
            try? FileManager.default.removeItem(at: target)
            do {
                try await PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: nil)
                lines.append("saved: copied \(resource.originalFilename)")
            } catch {
                lines.append("saved: copy failed \(error)")
            }
        }
        return lines
    }
}
