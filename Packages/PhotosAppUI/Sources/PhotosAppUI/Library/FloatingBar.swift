import SwiftUI

/// The floating bottom bar: Library | Collections in one glass capsule
/// with a round Search button; after scrolling the Library it morphs into a small
/// Library button, Years | Months | All, and a smaller Search button.
struct FloatingBar: View {
    @Bindable var ui: LibraryUIState
    @Namespace private var glass
    /// The selection pill slides between tabs (and stretches as it goes), like iOS 26.
    @Namespace private var pill
    @State private var stretching = false
    @State private var bounce: [AppSection: Int] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sizes of the Library | Collections capsule (a little smaller than the first version).
    private let tabWidth: CGFloat = 93
    private let tabHeight: CGFloat = 51

    private var showsTimeScale: Bool { ui.section == .library && ui.barMode == .timeScale }

    var body: some View {
        GlassGroup(spacing: 14) {
            HStack(alignment: .center, spacing: 0) {
                if showsTimeScale {
                    Button {
                        withAnimation(.smooth(duration: 0.35)) { ui.barMode = .tabs }
                    } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(.tint)
                            .frame(width: 54, height: 54)
                    }
                    .buttonStyle(.plain)
                    .glassSurface(Circle())
                    .glassMorphID("tabs", in: glass)
                    .accessibilityLabel("Library and Collections")
                    Spacer(minLength: 10)
                    timeScalePicker
                        .glassMorphID("scale", in: glass)
                    Spacer(minLength: 10)
                    searchButton(size: 54)
                } else {
                    tabs
                        .glassMorphID("tabs", in: glass)
                    Spacer(minLength: 10)
                    searchButton(size: tabHeight + 8)
                }
            }
            .padding(.horizontal, 20)
        }
        .animation(.smooth(duration: 0.35), value: showsTimeScale)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            tabButton(.library, title: "Library", symbol: "photo.on.rectangle.angled")
            tabButton(.collections, title: "Collections", symbol: "rectangle.stack.fill")
        }
        .padding(4)
        .glassSurface(Capsule())
    }

    private func tabButton(_ section: AppSection, title: LocalizedStringKey, symbol: String) -> some View {
        let selected = ui.section == section
        return Button {
            select(section)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 20.5, weight: .medium))
                    .symbolEffect(.bounce.down, value: bounce[section, default: 0])
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(width: tabWidth, height: tabHeight)
            .background {
                if selected {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .matchedGeometryEffect(id: "tab-pill", in: pill)
                        .scaleEffect(x: stretching ? 1.14 : 1, y: stretching ? 0.9 : 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(TabPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The pill slides to the tapped tab, stretching on the way and settling with a little
    /// bounce; the icon bounces too.
    private func select(_ section: AppSection) {
        guard !reduceMotion else {
            // Reduce Motion: no stretch or bounce, the pill just fades across.
            withAnimation(.easeInOut(duration: 0.2)) { ui.section = section }
            return
        }
        bounce[section, default: 0] += 1
        guard ui.section != section else { return }
        withAnimation(.spring(duration: 0.16)) { stretching = true }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { ui.section = section }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.55)) { stretching = false }
        }
    }

    private var timeScalePicker: some View {
        HStack(spacing: 2) {
            ForEach(TimeScale.allCases, id: \.self) { scale in
                let selected = ui.timeScale == scale
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { ui.timeScale = scale }
                } label: {
                    Text(scale.title)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 80, height: 44)
                        .background {
                            if selected {
                                Capsule().fill(Color.primary.opacity(0.08))
                                    .matchedGeometryEffect(id: "scale-pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(TabPressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(5)
        .glassSurface(Capsule())
    }

    private func searchButton(size: CGFloat) -> some View {
        Button {
            ui.showsSearch = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: size > 60 ? 24 : 21, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .glassSurface(Circle())
        .glassMorphID("search", in: glass)
        .accessibilityLabel("Search")
    }
}

extension TimeScale {
    var title: LocalizedStringKey {
        switch self {
        case .years: "Years"
        case .months: "Months"
        case .all: "All"
        }
    }
}

/// A tab grows a little under the finger, like iOS 26's tab bar.
private struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.08 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
