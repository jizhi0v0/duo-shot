import SwiftUI

/// The filename template as chips: one per variable, one per run of literal text.
///
/// Replaces a plain text field holding the whole template. Two things were wrong
/// with that field: the six variables it accepts were documented only in a
/// tooltip nobody hovers, and because focusing it selects all of its text, one
/// stray keystroke replaced the entire template — silently, permanently, and
/// observed in the wild.
struct FilenameTemplateEditor: View {
    @Binding var template: String

    /// Inserted between chips when a variable is added. Purely an authoring
    /// convenience — once inserted it is an ordinary text chip and can be edited
    /// or deleted like any other.
    @State private var separator: String = "-"
    /// Which text chip is open for editing, and its uncommitted value. A
    /// `TextField` living inside a chip was the obvious first try and it does not
    /// work: it refuses to hug its content inside a custom `Layout`, so every
    /// literal ran the full width of the window and each chip landed on its own
    /// line. Editing in a popover keeps the chip a chip.
    @State private var editingIndex: Int?
    @State private var draft: String = ""

    private var segments: [FilenameTemplate.Segment] {
        FilenameTemplate.parse(template)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChipFlow(spacing: 4, lineSpacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    chip(for: segment, at: index)
                }
                addMenu
            }

            HStack(spacing: 8) {
                Picker("Joiner", selection: $separator) {
                    Text("-").tag("-")
                    Text("_").tag("_")
                    Text("space").tag(" ")
                    Text("none").tag("")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .help("What gets inserted between chips when you add a variable.")

                Spacer()

                Button("Restore Default") {
                    template = FilenameFormatter.defaultTemplate
                }
                .controlSize(.small)
                .disabled(template == FilenameFormatter.defaultTemplate)
            }
        }
    }

    // MARK: - Chips

    @ViewBuilder
    private func chip(for segment: FilenameTemplate.Segment, at index: Int) -> some View {
        switch segment {
        case .variable(let variable):
            Menu {
                Picker("Variable", selection: variableBinding(at: index)) {
                    ForEach(FilenameTemplate.Variable.allCases) { option in
                        Text("\(option.label) — \(option.sample())").tag(option)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                moveButtons(at: index)
                Button("Remove", role: .destructive) { remove(at: index) }
            } label: {
                HStack(spacing: 4) {
                    Text(variable.label)
                    Text(variable.sample())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.tint.opacity(0.18), in: .capsule)

        case .text(let text):
            Button {
                draft = text
                editingIndex = index
            } label: {
                Text(text.isEmpty ? "empty" : text)
                    .foregroundStyle(text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: .capsule)
            }
            .buttonStyle(.plain)
            .help("Click to edit this text")
            .contextMenu {
                moveButtons(at: index)
                Button("Remove", role: .destructive) { remove(at: index) }
            }
            .popover(isPresented: editingBinding(at: index), arrowEdge: .bottom) {
                VStack(alignment: .trailing, spacing: 8) {
                    TextField("Text", text: $draft)
                        .frame(width: 180)
                        .onSubmit { commitDraft(at: index) }
                    HStack {
                        Button("Remove", role: .destructive) {
                            editingIndex = nil
                            remove(at: index)
                        }
                        Spacer()
                        Button("Done") { commitDraft(at: index) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(FilenameTemplate.Variable.allCases) { variable in
                Button("\(variable.label) — \(variable.sample())") { append(.variable(variable)) }
            }
            Divider()
            Button("Custom text") { append(.text("text")) }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.4), in: .capsule)
        .help("Add a variable or a piece of text")
    }

    @ViewBuilder
    private func moveButtons(at index: Int) -> some View {
        Button("Move Left") { move(at: index, by: -1) }
            .disabled(index == 0)
        Button("Move Right") { move(at: index, by: 1) }
            .disabled(index == segments.count - 1)
    }

    // MARK: - Editing

    private func variableBinding(at index: Int) -> Binding<FilenameTemplate.Variable> {
        Binding(
            get: {
                if case .variable(let variable) = segments[index] { return variable }
                return .year
            },
            set: { replace(at: index, with: .variable($0)) }
        )
    }

    private func editingBinding(at index: Int) -> Binding<Bool> {
        Binding(
            get: { editingIndex == index },
            set: { if !$0, editingIndex == index { commitDraft(at: index) } }
        )
    }

    /// Committing on close rather than per keystroke: the template round-trips
    /// through `parse` on every write, so a half-typed literal would re-split
    /// itself under the cursor. An emptied chip is dropped instead of persisted.
    private func commitDraft(at index: Int) {
        editingIndex = nil
        if draft.isEmpty {
            remove(at: index)
        } else {
            replace(at: index, with: .text(draft))
        }
    }

    private func append(_ segment: FilenameTemplate.Segment) {
        var updated = segments
        if case .variable = segment, !separator.isEmpty, let last = updated.last, last.text == nil {
            updated.append(.text(separator))
        }
        updated.append(segment)
        commit(updated)
    }

    private func replace(at index: Int, with segment: FilenameTemplate.Segment) {
        var updated = segments
        guard updated.indices.contains(index) else { return }
        updated[index] = segment
        commit(updated)
    }

    private func remove(at index: Int) {
        var updated = segments
        guard updated.indices.contains(index) else { return }
        updated.remove(at: index)
        commit(updated)
    }

    private func move(at index: Int, by offset: Int) {
        var updated = segments
        let target = index + offset
        guard updated.indices.contains(index), updated.indices.contains(target) else { return }
        updated.swapAt(index, target)
        commit(updated)
    }

    private func commit(_ updated: [FilenameTemplate.Segment]) {
        template = FilenameTemplate.string(from: updated)
    }
}

/// A left-to-right wrapping row. `HStack` would push the chips off the edge of a
/// 480 pt settings window as soon as a template has more than a few parts.
struct ChipFlow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, in: width)
        let height = rows.map(\.height).reduce(0, +)
            + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, max(widest, 0)), height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in layout(subviews: subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
