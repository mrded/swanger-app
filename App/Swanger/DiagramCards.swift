import OrderedJSON
import SwangerCore

/// A card in the diagram: an object, a choice or a tuple, with a row for each field, variant or
/// item.
struct DiagramCard: Identifiable {
  enum Style {
    /// The schema the page is about, or the card shown on its own.
    case top
    case fragment
    case choice
    case plain
  }

  /// The path to the card's schema.
  let id: FieldPath
  let title: String
  let node: SchemaNode
  let style: Style
  let rows: [CardRow]
  /// The card this one is opened from, and the row in it, by index.
  let parent: (card: Int, row: Int)?
  let depth: Int
}

/// One line of a card, all the same height so connectors can find them.
struct CardRow: Identifiable {
  enum Kind {
    /// The start of a group, such as "One of, by `method`".
    case heading
    case field(Field)
    case variant(Variant)
    /// An item at a position, an item past them, unlisted fields or fields matching a pattern.
    case other
  }

  /// The row's position in its card.
  let id: Int
  /// The path to the row's value. `nil` for a heading.
  let path: FieldPath?
  let kind: Kind
  let label: String
  /// The value's type, or for a variant, the discriminator value that picks it.
  let detail: String
  let node: SchemaNode?
  /// The card that clicking the row opens, if its value has one.
  let opens: FieldPath?

  var isHeading: Bool {
    if case .heading = kind { true } else { false }
  }
}

enum DiagramCards {
  /// The cards for `node` from `start`, and every card open below them, parents before children.
  static func cards(
    of node: SchemaNode, title: String, from start: FieldPath, open: Set<FieldPath>
  ) -> [DiagramCard] {
    guard let top = node.node(at: start) else { return [] }
    var cards: [DiagramCard] = []
    add(top, at: start, title: title, style: .top, parent: nil, depth: 0, open: open, to: &cards)
    return cards
  }

  /// `path`, or the nearest path above it that's a row when the cards on the way are open, such
  /// as `tags` for `tags[]`: an array that only holds items has no card, and its items no row.
  /// Empty when no row will do.
  static func nearestRow(to path: FieldPath, in node: SchemaNode) -> FieldPath {
    let rows = Set(
      cards(of: node, title: "", from: FieldPath(), open: Set(path.prefixes))
        .flatMap { $0.rows.compactMap(\.path) })
    return path.prefixes.reversed().first(where: rows.contains) ?? FieldPath()
  }

  /// The card a row's value opens, skipping arrays that only hold items: a row holding
  /// `array of Line` opens the `Line` card.
  static func cardPath(for node: SchemaNode, at path: FieldPath) -> (FieldPath, SchemaNode)? {
    if let array = node.array, array.prefixItems.isEmpty, node.choices.isEmpty,
      let items = array.items
    {
      return cardPath(for: items, at: path.appending(.items))
    }
    return hasCard(node) ? (path, node) : nil
  }

  private static func hasCard(_ node: SchemaNode) -> Bool {
    if !node.choices.isEmpty { return true }
    switch node.kind {
    case .object, .choice: return true
    case .array(let array): return !array.prefixItems.isEmpty
    case .scalar, .recursive, .unresolved, .never: return false
    }
  }

  private static func add(
    _ node: SchemaNode, at path: FieldPath, title: String, style: DiagramCard.Style,
    parent: (card: Int, row: Int)?, depth: Int, open: Set<FieldPath>, to cards: inout [DiagramCard]
  ) {
    let rows = rows(of: node, at: path)
    let index = cards.count
    cards.append(
      DiagramCard(
        id: path, title: title, node: node, style: style, rows: rows, parent: parent,
        depth: depth))
    for (rowIndex, row) in rows.enumerated() {
      guard let path = row.path, let node = row.node, open.contains(path),
        let (target, child) = cardPath(for: node, at: path)
      else { continue }
      let skipped = target.components.count - path.components.count
      let style: DiagramCard.Style =
        child.fragment != nil ? .fragment : child.choice != nil ? .choice : .plain
      add(
        child, at: target, title: row.label + String(repeating: "[]", count: skipped),
        style: style, parent: (index, rowIndex), depth: depth + 1, open: open, to: &cards)
    }
  }

  private static func rows(of node: SchemaNode, at path: FieldPath) -> [CardRow] {
    var rows: [CardRow] = []
    func add(
      _ kind: CardRow.Kind, _ component: FieldPath.Component, _ label: String,
      _ value: SchemaNode, detail: String? = nil
    ) {
      let rowPath = path.appending(component)
      rows.append(
        CardRow(
          id: rows.count, path: rowPath, kind: kind, label: label,
          detail: detail ?? value.typeDescription, node: value,
          opens: cardPath(for: value, at: rowPath)?.0))
    }
    func heading(_ text: String) {
      rows.append(
        CardRow(
          id: rows.count, path: nil, kind: .heading, label: text, detail: "", node: nil,
          opens: nil))
    }
    // Counted across the node's choices, as `SchemaNode.variants` lists them.
    var variantIndex = 0
    func addVariants(of choice: ChoiceSchema) {
      for variant in choice.variants {
        let detail = variant.discriminatorValue.map {
          "\(choice.discriminator ?? "") = \($0.literal)"
        }
        add(
          .variant(variant), .variant(variant.name, index: variantIndex), variant.name,
          variant.node, detail: detail)
        variantIndex += 1
      }
    }

    switch node.kind {
    case .object(let object):
      for field in object.fields {
        add(.field(field), .field(field.name), field.name, field.node)
      }
      for pattern in object.patternFields {
        add(.other, .patternField(pattern.pattern), "/\(pattern.pattern)/", pattern.node)
      }
      if case .schema(let other) = object.additionalFields {
        add(.other, .otherFields, "other fields", other)
      }
    case .choice(let choice):
      addVariants(of: choice)
    case .array(let array):
      for (index, item) in array.prefixItems.enumerated() {
        add(.other, .prefixItem(index), "[\(index)]", item)
      }
      if let items = array.items {
        add(.other, .items, array.prefixItems.isEmpty ? "items" : "the rest", items)
      }
    case .scalar, .recursive, .unresolved, .never:
      break
    }
    for choice in node.choices {
      let mode = choice.mode == .oneOf ? "One of" : "Any of"
      heading(choice.discriminator.map { "\(mode), by `\($0)`" } ?? mode)
      addVariants(of: choice)
    }
    return rows
  }
}

extension SchemaNode {
  /// Notes for the bottom of the node's card, after its rules.
  var cardNotes: [String] {
    var notes: [String] = []
    if case .forbidden = object?.additionalFields { notes.append("No other fields") }
    if isShapeInferred { notes.append("Has no `type`: other types are valid too") }
    for unresolved in unresolvedRefs { notes.append("Also `\(unresolved.ref)`, unresolved") }
    return notes
  }
}
