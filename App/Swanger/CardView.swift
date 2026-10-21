import SwangerCore
import SwiftUI

/// A card of the diagram: a header with the card's name and type, a row for each field or
/// variant, and its rules at the bottom.
struct CardView: View {
  let card: DiagramCard
  let openRows: Set<FieldPath>
  let selection: FieldPath?
  let highlight: FieldPath?
  let selectRow: (CardRow) -> Void
  let openOnItsOwn: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      ForEach(card.rows) { row in
        RowView(
          row: row, isOpen: row.path.map(openRows.contains) ?? false,
          isSelected: row.path != nil && row.path == selection,
          isHighlighted: row.path != nil && row.path == highlight
        )
        .onTapGesture { selectRow(row) }
      }
      footer
    }
    .frame(width: DiagramMetrics.cardWidth, alignment: .leading)
    .background(.background, in: shape)
    .overlay { shape.strokeBorder(accent.opacity(0.55), lineWidth: card.style == .top ? 1.5 : 1) }
    .clipShape(shape)
    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    .anchorPreference(key: CardBounds.self, value: .bounds) { [card.id: $0] }
  }

  private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8) }

  private var accent: Color {
    switch card.style {
    case .top: .swangerTeal
    case .fragment: .swangerViolet
    case .choice: .swangerAmber
    case .plain: .secondary
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(card.title).font(.headline).lineLimit(1)
      HStack(spacing: 4) {
        if card.node.fragment != nil {
          Image(systemName: "puzzlepiece.fill").foregroundStyle(Color.swangerViolet)
        }
        Text(card.node.typeDescription)
          .foregroundStyle(card.node.fragment != nil ? Color.swangerViolet : .secondary)
          .lineLimit(1)
      }
      .font(.caption)
    }
    .padding(.horizontal, 10)
    .frame(
      maxWidth: .infinity, minHeight: DiagramMetrics.headerHeight,
      maxHeight: DiagramMetrics.headerHeight, alignment: .leading
    )
    .background(accent.opacity(0.14))
    .contentShape(Rectangle())
    .onTapGesture(count: 2, perform: openOnItsOwn)
    .help(
      card.node.fragment != nil
        ? "Double-click to open \(card.node.typeDescription)"
        : "Double-click to show this card on its own")
  }

  @ViewBuilder private var footer: some View {
    let notes = card.node.cardNotes
    if !card.node.rules.isEmpty || !notes.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(card.node.rules.enumerated()), id: \.offset) { _, rule in
          Label {
            Text(markdown: rule.text)
          } icon: {
            Image(systemName: icon(for: rule.kind))
          }
          .foregroundStyle(Color.swangerAmber)
        }
        ForEach(notes, id: \.self) { note in
          Text(markdown: note).foregroundStyle(.secondary)
        }
      }
      .font(.caption)
      .fixedSize(horizontal: false, vertical: true)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.swangerAmber.opacity(0.07))
      .overlay(alignment: .top) { Divider() }
    }
  }

  private func icon(for kind: Rule.Kind) -> String {
    switch kind {
    case .constraint: "ruler"
    case .condition: "arrow.triangle.branch"
    case .choice: "arrow.triangle.swap"
    case .dependency: "link"
    }
  }
}

private struct RowView: View {
  let row: CardRow
  let isOpen: Bool
  let isSelected: Bool
  let isHighlighted: Bool

  var body: some View {
    HStack(spacing: 6) {
      marker.frame(width: 8)
      if row.isHeading {
        Text(markdown: row.label).font(.caption.weight(.semibold))
          .foregroundStyle(Color.swangerAmber)
      } else {
        Text(row.label)
          .strikethrough(isForbidden)
          .fontWeight(isRequired ? .semibold : .regular)
          .lineLimit(1)
          .layoutPriority(1)
        Spacer(minLength: 8)
        Text(row.detail)
          .foregroundStyle(detailColor)
          .lineLimit(1)
          .truncationMode(.middle)
        if row.opens != nil {
          Image(systemName: isOpen ? "chevron.right.circle.fill" : "chevron.right")
            .foregroundStyle(isOpen ? accent : .secondary)
            .frame(width: 14)
        }
      }
    }
    .font(.callout)
    .padding(.horizontal, 8)
    .frame(height: DiagramMetrics.rowHeight)
    .background(background)
    .contentShape(Rectangle())
    .help(help)
  }

  private var field: Field? {
    if case .field(let field) = row.kind { field } else { nil }
  }

  private var isRequired: Bool { field?.isRequired == true }
  private var isForbidden: Bool { field?.isForbidden == true }

  private var accent: Color {
    if case .variant = row.kind { return .swangerAmber }
    return row.node?.fragment != nil ? .swangerViolet : .swangerTeal
  }

  private var detailColor: Color {
    if case .variant = row.kind { return .swangerAmber }
    return row.node?.fragment != nil ? .swangerViolet : .secondary
  }

  @ViewBuilder private var marker: some View {
    if isRequired && !isForbidden {
      Circle().fill(Color.swangerTeal).frame(width: 6, height: 6)
        .accessibilityLabel("Required")
    } else if case .variant = row.kind {
      Image(systemName: "arrow.turn.down.right").font(.caption2)
        .foregroundStyle(Color.swangerAmber)
    }
  }

  @ViewBuilder private var background: some View {
    if isSelected {
      Color.accentColor.opacity(isHighlighted ? 0.35 : 0.2)
    } else if isOpen {
      accent.opacity(0.08)
    } else {
      Color.clear
    }
  }

  private var help: String {
    var lines: [String] = []
    if let field {
      lines.append(field.isForbidden ? "Not allowed" : field.isRequired ? "Required" : "Optional")
      if let definedIn = field.definedIn { lines.append("From \(definedIn.name)") }
    }
    if let description = row.node?.description { lines.append(description) }
    return lines.joined(separator: "\n")
  }
}
