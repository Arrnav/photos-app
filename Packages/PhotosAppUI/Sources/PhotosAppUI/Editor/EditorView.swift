import AVKit
import SwiftUI

/// The Edit screen (reference v3–v7): Cancel / Done; a row with the tool's own buttons,
/// its name, and ···; the preview; the tool's controls; and the tool picker at the bottom.
struct EditorView: View {
    @State var model: EditorModel
    let onFinish: (_ saved: Bool) -> Void
    @State private var isPlaying = false
    @State private var playhead: Double = 0
    @State private var confirmCancel = false
    private let tick = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            topRow
            toolRow.padding(.top, 10)
            preview
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            controls
                .frame(height: 150)
            toolPicker
                .padding(.bottom, 8)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .task { await model.load() }
        .onReceive(tick) { _ in
            guard model.item.isVideo else { return }
            playhead = model.player.currentTime().seconds
            isPlaying = model.player.timeControlStatus == .playing
            if let end = model.state.trimEnd, playhead >= end { model.player.pause(); seekTrimStart() }
        }
        .alert("Couldn't Save", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Discard Changes?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { onFinish(false) }
        }
    }

    // MARK: Top

    private var topRow: some View {
        HStack {
            Button("Cancel") {
                if model.hasChanges { confirmCancel = true } else { onFinish(false) }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 18).frame(height: 38)
            .glassSurface(Capsule())
            Spacer()
            Button {
                Task { if await model.save() { onFinish(true) } }
            } label: {
                if model.isSaving { ProgressView().frame(width: 52) } else { Text("Done") }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(model.hasChanges ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 18).frame(height: 38)
            .glassSurface(Capsule())
            .disabled(!model.hasChanges || model.isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var toolRow: some View {
        HStack {
            leftGroup.frame(minWidth: 110, alignment: .leading)
            Spacer()
            Text(model.tool.title.uppercased())
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            rightGroup.frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var leftGroup: some View {
        switch model.tool {
        case .video, .audioMix:
            circle(model.state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "Mute") {
                model.beginChange(); model.state.muted.toggle()
            }
        case .adjust, .filters:
            HStack(spacing: 22) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo)
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo)
            }
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).frame(height: 42)
            .glassSurface(Capsule())
        case .crop:
            HStack(spacing: 22) {
                Button { model.beginChange(); model.state.flipped.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .accessibilityLabel("Flip")
                Button { model.beginChange(); model.state.quarterTurns += 1 } label: { Image(systemName: "rotate.left") }
                    .accessibilityLabel("Rotate")
            }
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).frame(height: 42)
            .glassSurface(Capsule())
        }
    }

    @ViewBuilder
    private var rightGroup: some View {
        HStack(spacing: 18) {
            if model.tool == .crop {
                Menu {
                    ForEach(CropAspect.allCases) { aspect in
                        Button(aspect.title) { model.beginChange(); model.state.crop = aspect.rect(for: model.preview?.size ?? CGSize(width: 1, height: 1)) }
                    }
                } label: { Image(systemName: "aspectratio") }
                    .accessibilityLabel("Aspect Ratio")
            }
            Menu {
                Button("Revert to Original", role: .destructive) { model.revertToOriginal() }
                    .disabled(model.state.isIdentity)
            } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("More")
        }
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 16).frame(height: 42)
        .glassSurface(Capsule())
    }

    private func circle(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 42, height: 42)
        }
        .glassSurface(Circle())
        .accessibilityLabel(label)
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        ZStack(alignment: .bottom) {
            if model.item.isVideo {
                PlayerLayerView(player: model.player)
                    .overlay { if model.tool == .crop { CropOverlay(model: model) } }
                if model.tool != .video { videoBar.padding(16) }
            } else if let image = model.preview {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay { if model.tool == .crop { CropOverlay(model: model) } }
            } else {
                ProgressView()
            }
            if model.tool == .filters {
                Text(model.state.filter.title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, model.item.isVideo ? 64 : 16)
            }
        }
    }

    private var videoBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22)).foregroundStyle(.white)
                }
                GeometryReader { geometry in
                    let fraction = model.duration > 0 ? playhead / model.duration : 0
                    Capsule().fill(.white.opacity(0.35)).frame(height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: geometry.size.width * fraction, height: 4) }
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let f = min(max(value.location.x / geometry.size.width, 0), 1)
                            model.player.seek(to: CMTime(seconds: model.duration * f, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                        })
                }
                .frame(height: 24)
            }
            HStack {
                Text(VideoControlsView.format(playhead))
                Spacer()
                Text(VideoControlsView.format(model.duration))
            }
            .font(.system(size: 15, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.leading, 36)
        }
        .shadow(color: .black.opacity(0.3), radius: 4)
    }

    private func togglePlay() {
        if isPlaying { model.player.pause() } else {
            if let end = model.state.trimEnd, playhead >= end - 0.05 { seekTrimStart() }
            model.player.play()
        }
    }

    private func seekTrimStart() {
        model.player.seek(to: CMTime(seconds: model.state.trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Tool controls

    @ViewBuilder
    private var controls: some View {
        switch model.tool {
        case .video: TrimStrip(model: model, isPlaying: isPlaying, playhead: playhead, togglePlay: togglePlay).padding(.horizontal, 16)
        case .audioMix: AudioMixPicker(model: model)
        case .adjust: AdjustControls(model: model)
        case .filters: FilterStrip(model: model)
        case .crop: CropControls(model: model)
        }
    }

    private var toolPicker: some View {
        HStack(spacing: 4) {
            ForEach(model.tools) { tool in
                let selected = model.tool == tool
                Button { withAnimation(.snappy) { model.tool = tool } } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 6)).foregroundStyle(.yellow).opacity(selected ? 1 : 0)
                        Image(systemName: tool.symbol).font(.system(size: 19, weight: selected ? .semibold : .regular))
                        Text(tool.title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: 60, height: 56)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .glassSurface(Capsule())
    }
}

// MARK: - Pieces

/// A ruler slider (-1…1): ticks scroll under a fixed yellow mark; haptic at zero.
struct RulerSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var onBegin: () -> Void = {}
    @State private var startValue: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let pointsPerUnit = width * 0.9 / (range.upperBound - range.lowerBound)
            Canvas { context, size in
                let offset = -value * pointsPerUnit
                for i in -40...40 {
                    let x = size.width / 2 + CGFloat(i) * pointsPerUnit / 20 + offset
                    guard x > 0, x < size.width else { continue }
                    let major = i % 5 == 0
                    let rect = CGRect(x: x - 1, y: size.height / 2 - (major ? 14 : 10), width: 2, height: major ? 28 : 20)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.secondary.opacity(major ? 0.7 : 0.4)))
                }
                let mark = CGRect(x: size.width / 2 - 1.5, y: size.height / 2 - 20, width: 3, height: 40)
                context.fill(Path(roundedRect: mark, cornerRadius: 1.5), with: .color(.yellow))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    if startValue == nil { startValue = value; onBegin() }
                    let new = min(max((startValue ?? 0) - drag.translation.width / pointsPerUnit, range.lowerBound), range.upperBound)
                    if (value < 0 && new >= 0) || (value > 0 && new <= 0) { UISelectionFeedbackGenerator().selectionChanged() }
                    value = abs(new) < 0.02 ? 0 : new
                }
                .onEnded { _ in startValue = nil })
        }
        .frame(height: 48)
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100))")
        .accessibilityAdjustableAction { direction in
            value = min(max(value + (direction == .increment ? 0.1 : -0.1), range.lowerBound), range.upperBound)
        }
    }
}

private struct AdjustControls: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    dial(selection: .auto, symbol: "wand.and.stars", title: String(localized: "Auto"), active: model.state.auto) {
                        if model.selection == .auto { model.beginChange(); model.state.auto.toggle() }
                        model.selection = .auto
                    }
                    ForEach(EditState.Adjustment.allCases, id: \.self) { adjustment in
                        dial(selection: .adjustment(adjustment), symbol: adjustment.symbol, title: adjustment.title, active: model.state.value(adjustment) != 0) {
                            model.selection = .adjustment(adjustment)
                        }
                    }
                }
                .padding(.horizontal, 160)
            }
            .scrollIndicators(.hidden)
            if case .adjustment(let adjustment) = model.selection {
                RulerSlider(value: Binding(
                    get: { model.state.value(adjustment) },
                    set: { model.state.adjustments[adjustment] = $0 == 0 ? nil : $0 }
                ), range: adjustment.allowsNegative ? -1...1 : 0...1, onBegin: { model.beginChange() })
                .padding(.horizontal, 24)
            } else {
                Text(model.state.auto ? "AUTO ON" : "AUTO").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(height: 48)
            }
        }
    }

    private func dial(selection: EditorModel.Selection, symbol: String, title: String, active: Bool, action: @escaping () -> Void) -> some View {
        let selected = model.selection == selection
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(selected ? Color.primary : .secondary)
                .frame(width: 52, height: 52)
                .background(Circle().fill(selected ? Color(.systemGray4) : .clear))
                .overlay(Circle().stroke(active ? Color.yellow : Color(.systemGray3), lineWidth: active ? 2 : 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct FilterStrip: View {
    @Bindable var model: EditorModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(EditState.Filter.allCases, id: \.self) { filter in
                    let selected = model.state.filter == filter
                    Button {
                        model.beginChange()
                        model.state.filter = filter
                    } label: {
                        VStack(spacing: 6) {
                            Circle().fill(.primary).frame(width: 6, height: 6).opacity(selected ? 1 : 0)
                            Group {
                                if let image = model.filterThumbnails[filter] { Image(uiImage: image).resizable().scaledToFill() } else { Color(.systemGray5) }
                            }
                            .frame(width: selected ? 112 : 100, height: 108)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white, lineWidth: selected ? 4 : 0))
                            .shadow(radius: selected ? 4 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(filter.title.capitalized)
                }
            }
            .padding(.horizontal, 140)
        }
        .scrollIndicators(.hidden)
    }
}

private struct CropControls: View {
    @Bindable var model: EditorModel
    @State private var dial: Dial = .straighten

    enum Dial: CaseIterable { case straighten, vertical, horizontal }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 30) {
                ForEach(Dial.allCases, id: \.self) { item in
                    let selected = dial == item
                    Button { dial = item } label: {
                        Image(systemName: symbol(item))
                            .font(.system(size: 22))
                            .foregroundStyle(.primary)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(selected ? Color(.systemGray4) : .clear))
                            .overlay(Circle().stroke(Color(.systemGray3), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            RulerSlider(value: binding, onBegin: { model.beginChange() }).padding(.horizontal, 24)
        }
    }

    private func symbol(_ dial: Dial) -> String {
        switch dial {
        case .straighten: "level"
        case .vertical: "trapezoid.and.line.vertical"
        case .horizontal: "trapezoid.and.line.horizontal"
        }
    }

    private var binding: Binding<Double> {
        switch dial {
        case .straighten: Binding(get: { model.state.straighten / 45 }, set: { model.state.straighten = $0 * 45 })
        case .vertical: Binding(get: { model.state.vertical }, set: { model.state.vertical = $0 })
        case .horizontal: Binding(get: { model.state.horizontal }, set: { model.state.horizontal = $0 })
        }
    }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case original, square, wide, standard, portrait, tall
    var id: Self { self }

    var title: String {
        switch self {
        case .original: String(localized: "Original")
        case .square: String(localized: "Square")
        case .wide: "16:9"
        case .standard: "4:3"
        case .portrait: "3:4"
        case .tall: "9:16"
        }
    }

    /// The largest centred crop with this shape (unit coordinates).
    func rect(for size: CGSize) -> CGRect {
        let target: CGFloat
        switch self {
        case .original: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .square: target = 1
        case .wide: target = 16.0 / 9
        case .standard: target = 4.0 / 3
        case .portrait: target = 3.0 / 4
        case .tall: target = 9.0 / 16
        }
        let current = size.width / max(size.height, 1)
        if current > target {
            let w = target / current
            return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
        let h = current / target
        return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
    }
}

/// Crop frame with draggable corners over the preview (the preview shows the uncropped photo
/// while cropping, so the frame can be moved back out).
private struct CropOverlay: View {
    @Bindable var model: EditorModel
    @State private var start: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let c = model.state.crop
            let rect = CGRect(x: c.minX * size.width, y: c.minY * size.height, width: c.width * size.width, height: c.height * size.height)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                Rectangle().stroke(.white, lineWidth: 1).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                ForEach(0..<4, id: \.self) { corner in
                    let point = CGPoint(x: corner % 2 == 0 ? rect.minX : rect.maxX, y: corner < 2 ? rect.minY : rect.maxY)
                    Rectangle().fill(.white).frame(width: 22, height: 22).mask(CornerShape(corner: corner))
                        .position(point)
                        .gesture(DragGesture().onChanged { drag in
                            if start == nil { start = model.state.crop; model.beginChange() }
                            guard let s = start else { return }
                            let dx = drag.translation.width / size.width, dy = drag.translation.height / size.height
                            var r = s
                            if corner % 2 == 0 { r.origin.x = min(max(s.minX + dx, 0), s.maxX - 0.1); r.size.width = s.maxX - r.minX } else { r.size.width = min(max(s.width + dx, 0.1), 1 - s.minX) }
                            if corner < 2 { r.origin.y = min(max(s.minY + dy, 0), s.maxY - 0.1); r.size.height = s.maxY - r.minY } else { r.size.height = min(max(s.height + dy, 0.1), 1 - s.minY) }
                            model.state.crop = r
                        }.onEnded { _ in start = nil })
                }
            }
        }
    }
}

private struct CornerShape: Shape {
    let corner: Int
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let t: CGFloat = 4
        let horizontal = CGRect(x: corner % 2 == 0 ? rect.midX : 0, y: corner < 2 ? rect.midY - t / 2 : rect.midY - t / 2, width: rect.width / 2 + t / 2, height: t)
        let vertical = CGRect(x: rect.midX - t / 2, y: corner < 2 ? rect.midY : 0, width: t, height: rect.height / 2 + t / 2)
        path.addRect(horizontal.offsetBy(dx: corner % 2 == 0 ? -t / 2 : 0, dy: 0))
        path.addRect(vertical)
        return path
    }
}

/// Video › trim: frames with ⟨ ⟩ handles, a white playhead, and play at the left (v7).
private struct TrimStrip: View {
    @Bindable var model: EditorModel
    let isPlaying: Bool
    let playhead: Double
    let togglePlay: () -> Void
    @State private var dragStart: (start: Double, end: Double)?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 26)).foregroundStyle(.white).frame(width: 64, height: 64)
            }
            .background(Color(.systemGray))
            GeometryReader { geometry in
                let width = geometry.size.width - 28
                let duration = max(model.duration, 0.01)
                let start = model.state.trimStart / duration
                let end = (model.state.trimEnd ?? duration) / duration
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.frames.enumerated()), id: \.offset) { _, frame in
                            Image(uiImage: frame).resizable().scaledToFill().frame(width: width / CGFloat(max(model.frames.count, 1)), height: 56).clipped()
                        }
                    }
                    .frame(width: width, height: 56)
                    .offset(x: 14)
                    // Trimmed-away parts dimmed; the kept range framed in yellow (when trimmed).
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(start > 0 || end < 1 ? Color.yellow : Color(.systemGray2), lineWidth: 4)
                        .frame(width: CGFloat(end - start) * width + 28, height: 64)
                        .offset(x: CGFloat(start) * width)
                    handle(left: true).offset(x: CGFloat(start) * width)
                        .gesture(DragGesture().onChanged { drag in move(left: true, by: drag.translation.width / width * duration) }.onEnded { _ in dragStart = nil })
                    handle(left: false).offset(x: CGFloat(end) * width + 14)
                        .gesture(DragGesture().onChanged { drag in move(left: false, by: drag.translation.width / width * duration) }.onEnded { _ in dragStart = nil })
                    Capsule().fill(.white).frame(width: 4, height: 70).shadow(radius: 2)
                        .offset(x: 14 + CGFloat(playhead / duration) * width - 2)
                }
            }
            .frame(height: 64)
            .background(Color(.systemGray3))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func handle(left: Bool) -> some View {
        Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right")
            .font(.system(size: 20, weight: .bold)).foregroundStyle(.black.opacity(0.7))
            .frame(width: 14, height: 64)
            .background(Color.yellow.opacity(0.001))
    }

    private func move(left: Bool, by seconds: Double) {
        if dragStart == nil {
            dragStart = (model.state.trimStart, model.state.trimEnd ?? model.duration)
            model.beginChange()
            model.player.pause()
        }
        guard let s = dragStart else { return }
        if left {
            model.state.trimStart = min(max(s.start + seconds, 0), s.end - 0.5)
            model.player.seek(to: CMTime(seconds: model.state.trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let end = min(max(s.end + seconds, s.start + 0.5), model.duration)
            model.state.trimEnd = end >= model.duration - 0.01 ? nil : end
            model.player.seek(to: CMTime(seconds: end, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
}

/// Audio Mix (v3): Standard · In-Frame · Studio · Cinematic, the chosen one in a yellow pill.
private struct AudioMixPicker: View {
    @Bindable var model: EditorModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 24) {
                ForEach(EditState.AudioMix.allCases, id: \.self) { mix in
                    let selected = model.state.audioMix == mix
                    Button {
                        model.beginChange()
                        model.state.audioMix = mix
                    } label: {
                        Text(mix.title)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(selected ? Color.black : .secondary)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .background(Capsule().fill(selected ? Color.yellow : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 150)
        }
        .scrollIndicators(.hidden)
    }
}

/// An `AVPlayerLayer` in SwiftUI.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView { PlayerView(player: player) }
    func updateUIView(_ view: PlayerView, context: Context) {}
}
