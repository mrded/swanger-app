import SwangerCore
import SwiftUI

/// What a row's value is, shown beside the row while the pointer rests on it: its type and
/// presence, the rules its values must meet, and its description. The inspector has the rest.
struct RowInfo: View {
  let row: CardRow

  static let width: CGFloat = 280

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(row.label).font(.headline).lineLimit(1)
        Spacer(minLength: 0)
        if let node = row.node {
          Text(node.typeDescription)
            .foregroundStyle(node.fragment != nil ? Color.swangerViolet : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      if let mark = DiagramMark(row) {
        HStack(spacing: 6) {
          DiagramMarkView(mark: mark)
          Text(mark.meaning).foregroundStyle(mark == .required ? Color.swangerTeal : .primary)
        }
      }
      if case .variant(let variant) = row.kind, variant.discriminatorValue != nil {
        Text("Picked when \(row.detail)")
      }
      ForEach(Array(decidedBy.enumerated()), id: \.offset) { _, rule in
        Label {
          Text(markdown: rule.text)
        } icon: {
          Image(systemName: "arrow.triangle.branch")
        }
        .foregroundStyle(Color.swangerAmber)
      }
      if let node = row.node { ValueFacts(node: node, hasCard: row.opens != nil) }
      if let definedIn = field?.definedIn {
        Label(definedIn.name, systemImage: "puzzlepiece")
          .foregroundStyle(Color.swangerViolet)
      }
    }
    .font(.caption)
    .fixedSize(horizontal: false, vertical: true)
    .padding(10)
    .frame(width: Self.width, alignment: .leading)
    .background(.regularMaterial, in: shape)
    .overlay { shape.strokeBorder(.separator) }
    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
  }

  private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8) }

  private var field: Field? {
    if case .field(let field) = row.kind { field } else { nil }
  }

  /// The rules that require or forbid the field, when it depends on them.
  private var decidedBy: [Rule] {
    guard let field, field.presence == .conditional else { return [] }
    return field.decidedBy
  }
}

/// A value's flags, rules, default and description. The rules of a value with a card are on its
/// card, so they're left out; an array of scalars, which has no card, has its items' rules too.
private struct ValueFacts: View {
  let node: SchemaNode
  let hasCard: Bool

  var body: some View {
    if !flags.isEmpty {
      Text(flags.joined(separator: ", ")).foregroundStyle(.secondary)
    }
    ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
      Label {
        Text(markdown: rule)
      } icon: {
        Image(systemName: "ruler")
      }
      .foregroundStyle(Color.swangerAmber)
    }
    if let value = node.defaultValue {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("Default").foregroundStyle(.secondary)
        Text(value.literal).monospaced().lineLimit(3)
      }
    }
    if let description = node.description {
      Text(markdown: description).foregroundStyle(.secondary).lineLimit(6)
    }
  }

  private var rules: [String] {
    guard !hasCard else { return [] }
    var rules = node.rules.map(\.text)
    if let items = node.array?.items, items.scalar != nil {
      rules += items.rules.map { "Each item \($0.text)" }
    }
    return rules
  }

  private var flags: [String] {
    var flags: [String] = []
    if node.isDeprecated { flags.append("Deprecated") }
    if node.isReadOnly { flags.append("Read only") }
    if node.isWriteOnly { flags.append("Write only") }
    return flags
  }
}
