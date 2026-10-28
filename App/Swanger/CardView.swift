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
  /// Told the row under the pointer, by its position, or `nil` when it leaves the card's rows.
  let hoverRow: (Int?) -> Void
  let openOnItsOwn: () -> Void

  /// The rule under the pointer, by its position in the card's rules.
  @State private var hoveredRule: Int?
  /// The row under the pointer, whose field's deciding rules light up.
  @State private var hoveredRow: Int?

  var body: some View {
    let ruled = ruledRows
    VStack(alignment: .leading, spacing: 0) {
      header
      ForEach(card.rows) { row in
        RowView(
          row: row, isOpen: row.path.map(openRows.contains) ?? false,
          isSelected: row.path != nil && row.path == selection,
          isHighlighted: row.path != nil && row.path == highlight,
          isRuled: ruled.contains(row.id)
        )
        .onTapGesture { selectRow(row) }
        .onHover { hovering in
          if hovering {
            hoveredRow = row.id
          } else if hoveredRow == row.id {
            hoveredRow = nil
          }
        }
      }
      footer
    }
    .onChange(of: hoveredRow) { _, row in hoverRow(row) }
    .frame(width: DiagramMetrics.cardWidth, alignment: .leading)
    .background(.background, in: shape)
    .overlay { shape.strokeBorder(accent.opacity(0.55), lineWidth: card.style == .top ? 1.5 : 1) }
    .clipShape(shape)
    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    // After the clip, so the lines can run outside the card.
    .overlayPreferenceValue(RuleBounds.self) { anchors in
      if let hoveredRule, let anchor = anchors[hoveredRule], !ruled.isEmpty {
        GeometryReader { proxy in
          RuleLines(rows: ruled, rule: proxy[anchor])
        }
      }
    }
    .anchorPreference(key: CardBounds.self, value: .bounds) { [card.id: $0] }
  }

  /// The rows whose fields the hovered rule names, in order.
  private var ruledRows: [Int] {
    guard let hoveredRule, card.node.rules.indices.contains(hoveredRule) else { return [] }
    let names = card.node.rules[hoveredRule].fields
    return card.rows.compactMap { row in
      if case .field(let field) = row.kind, names.contains(field.name) { row.id } else { nil }
    }
  }

  /// Whether rule `index` is hovered, or decides the field of the hovered row.
  private func isLit(rule index: Int) -> Bool {
    if hoveredRule == index { return true }
    guard let hoveredRow, card.rows.indices.contains(hoveredRow),
      case .field(let field) = card.rows[hoveredRow].kind
    else { return false }
    return field.decidedBy.contains(card.node.rules[index])
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
        ForEach(Array(card.node.rules.enumerated()), id: \.offset) { index, rule in
          Label {
            Text(markdown: rule.text)
          } icon: {
            Image(systemName: icon(for: rule.kind))
          }
          .foregroundStyle(Color.swangerAmber)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background {
            if isLit(rule: index) {
              Color.swangerAmber.opacity(0.15).padding(-3)
            }
          }
          .contentShape(Rectangle())
          .onHover { hovering in
            if hovering {
              hoveredRule = index
            } else if hoveredRule == index {
              hoveredRule = nil
            }
          }
          .anchorPreference(key: RuleBounds.self, value: .bounds) { [index: $0] }
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

/// Where each of a card's rules is in the footer, by its position in the card's rules.
private struct RuleBounds: PreferenceKey {
  static let defaultValue: [Int: Anchor<CGRect>] = [:]

  static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
    value.merge(nextValue()) { $1 }
  }
}

/// Lines from the left edge of each of `rows` down outside the card's left edge and into the
/// rule at `rule`. Each row's line is a step further out than the one below it, so they nest
/// without crossing.
private struct RuleLines: View {
  let rows: [Int]
  let rule: CGRect

  var body: some View {
    // Paths rather than a `Canvas`, which would clip the lines to the card.
    let end = CGPoint(x: rule.minX - 2, y: rule.midY)
    Path { path in
      // Kept within the gap between columns.
      let step = min(6, (DiagramMetrics.columnGap - 12) / CGFloat(rows.count))
      for (order, row) in rows.enumerated() {
        let y = DiagramMetrics.rowMiddle(row)
        let x = -step * CGFloat(rows.count - order)
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x, y: end.y))
        path.addLine(to: end)
      }
    }
    .stroke(
      Color.swangerAmber, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
    )
    .overlay {
      Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5))
        .fill(Color.swangerAmber)
    }
    .allowsHitTesting(false)
  }
}

private struct RowView: View {
  let row: CardRow
  let isOpen: Bool
  let isSelected: Bool
  let isHighlighted: Bool
  /// Named by the rule under the pointer.
  let isRuled: Bool

  var body: some View {
    HStack(spacing: 6) {
      marker.frame(width: 8)
      if row.isHeading {
        Text(markdown: row.label).font(.caption.weight(.semibold))
          .foregroundStyle(Color.swangerAmber)
      } else {
        Text(row.label)
          .strikethrough(presence == .forbidden)
          .fontWeight(presence == .required ? .semibold : .regular)
          .foregroundStyle(presence == .forbidden ? .secondary : .primary)
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
  }

  private var field: Field? {
    if case .field(let field) = row.kind { field } else { nil }
  }

  private var presence: Presence? { field?.presence }

  private var accent: Color {
    if case .variant = row.kind { return .swangerAmber }
    return row.node?.fragment != nil ? .swangerViolet : .swangerTeal
  }

  private var detailColor: Color {
    if case .variant = row.kind { return .swangerAmber }
    return row.node?.fragment != nil ? .swangerViolet : .secondary
  }

  @ViewBuilder private var marker: some View {
    if let mark = DiagramMark(row) { DiagramMarkView(mark: mark) }
  }

  @ViewBuilder private var background: some View {
    if isSelected {
      Color.accentColor.opacity(isHighlighted ? 0.35 : 0.2)
    } else if isRuled {
      Color.swangerAmber.opacity(0.18)
    } else if isOpen {
      accent.opacity(0.08)
    } else {
      Color.clear
    }
  }
}
