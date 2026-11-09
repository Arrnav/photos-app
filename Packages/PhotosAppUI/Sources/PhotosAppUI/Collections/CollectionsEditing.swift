import SwiftUI

/// ··· › Reorder: drag sections into a new order and choose which ones show.
struct ReorderSectionsSheet: View {
    @Bindable var collections: CollectionsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(collections.order) { section in
                        let shown = !collections.hiddenSections.contains(section)
                        Button {
                            if shown { collections.hiddenSections.insert(section) } else { collections.hiddenSections.remove(section) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: shown ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(shown ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                Text(section.title).foregroundStyle(.primary)
                            }
                        }
                        .accessibilityAddTraits(shown ? .isSelected : [])
                    }
                    .onMove { from, to in collections.order.move(fromOffsets: from, toOffset: to) }
                } footer: {
                    Text("Drag to change the order of Collections. Sections that aren't ticked are hidden.")
                }
                Section {
                    Button("Reset to Default Order") {
                        collections.order = CollectionSection.allCases
                        collections.hiddenSections = []
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DoneCheckButton { dismiss() }
                }
            }
        }
    }
}

/// Pinned › Edit: add and remove pinned collections, and drag to reorder them.
struct PinnedEditorSheet: View {
    @Bindable var collections: CollectionsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Pinned") {
                    ForEach(collections.pinned) { smart in
                        row(smart, pinned: true)
                    }
                    .onMove { from, to in collections.pinned.move(fromOffsets: from, toOffset: to) }
                }
                let suggestions = SmartCollection.pinnable.filter { !collections.pinned.contains($0) }
                if !suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggestions) { smart in
                            row(smart, pinned: false)
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Pinned")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DoneCheckButton { dismiss() }
                }
            }
        }
    }

    private func row(_ smart: SmartCollection, pinned: Bool) -> some View {
        HStack(spacing: 14) {
            Button {
                withAnimation {
                    if pinned { collections.pinned.removeAll { $0 == smart } } else { collections.pinned.append(smart) }
                }
            } label: {
                Image(systemName: pinned ? "minus.circle.fill" : "plus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, pinned ? Color.red : Color.green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pinned ? "Unpin \(smart.title)" : "Pin \(smart.title)")
            Image(systemName: smart.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(smart.title)
        }
    }
}

/// The round blue ✓ that finishes a sheet.
struct DoneCheckButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Done")
    }
}
