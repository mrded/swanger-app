import OrderedJSON
import SwangerCore
import SwiftUI

/// The selected row's details: its type, constraints, rules, and the fragments it's defined in
/// and used in. With nothing selected, the page's schema.
struct InspectorView: View {
  let spec: Spec
  let store: SpecStore

  var body: some View {
    switch store.view.page {
    case .overview:
      empty
    case .root(let id):
      if let root = spec.root(id) {
        details(of: root.node, title: root.name) { RootDetails(root: root) }
      } else {
        empty
      }
    case .fragment(let id):
      if let fragment = spec.fragment(at: id) {
        details(of: fragment.node, title: fragment.name) {
          FragmentDetails(fragment: fragment, spec: spec, store: store)
        }
      } else {
        empty
      }
    }
  }

  @ViewBuilder
  private func details(
    of node: SchemaNode, title: String, @ViewBuilder page: () -> some View
  ) -> some View {
    if let path = store.view.diagram.selection, let selected = node.node(at: path) {
      FieldDetails(
        path: path, node: selected, field: node.field(at: path),
        enclosing: enclosingFragment(of: path, in: node), spec: spec, store: store)
    } else {
      page()
    }
  }

  /// The nearest fragment the value at `path` is written in, not counting itself.
  private func enclosingFragment(of path: FieldPath, in root: SchemaNode) -> FragmentRef? {
    var nearest = root.fragment
    for prefix in path.prefixes.dropLast() {
      if let fragment = root.node(at: prefix)?.fragment { nearest = fragment }
    }
    return nearest
  }

  private var empty: some View {
    ContentUnavailableView(
      "No Selection", systemImage: "sidebar.trailing",
      description: Text("Select a field to see its details."))
  }
}

private struct FieldDetails: View {
  let path: FieldPath
  let node: SchemaNode
  let field: Field?
  let enclosing: FragmentRef?
  let spec: Spec
  let store: SpecStore

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 4) {
          Text(name).font(.title3.bold())
          Text(path.description).font(.caption.monospaced()).foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        LabeledContent("Type") {
          Text(node.typeDescription)
            .foregroundStyle(node.fragment != nil ? Color.swangerViolet : .primary)
        }
        if let field {
          LabeledContent("Presence") {
            Text(field.isForbidden ? "Not allowed" : field.isRequired ? "Required" : "Optional")
              .foregroundStyle(
                field.isRequired && !field.isForbidden ? Color.swangerTeal : .primary)
          }
        }
        if !flags.isEmpty { LabeledContent("Also", value: flags.joined(separator: ", ")) }
        if let description = node.description {
          Text(markdown: description).textSelection(.enabled)
        }
      }
      if let scalar = node.scalar { ScalarSection(scalar: scalar) }
      ForEach(Array(itemsWithoutCard.enumerated()), id: \.offset) { depth, items in
        ItemsSection(items: items, depth: depth)
      }
      valuesSection
      if !node.rules.isEmpty || !node.cardNotes.isEmpty {
        Section("Rules") {
          ForEach(Array(node.rules.enumerated()), id: \.offset) { _, rule in
            Text(markdown: rule.text).foregroundStyle(Color.swangerAmber)
          }
          ForEach(node.cardNotes, id: \.self) { Text(markdown: $0).foregroundStyle(.secondary) }
        }
      }
      Section("Defined in") {
        if let definedIn = field?.definedIn ?? enclosing {
          FragmentLink(fragment: definedIn, spec: spec, store: store)
        } else {
          Text("This schema").foregroundStyle(.secondary)
        }
      }
      if let fragment = node.fragment {
        UsedInSection(fragment: fragment, spec: spec, store: store)
      }
    }
    .formStyle(.grouped)
  }

  private var name: String {
    switch path.components.last {
    case .field(let name), .variant(let name, _): name
    case .items: "Items"
    case .prefixItem(let index): "Item \(index)"
    case .otherFields: "Other fields"
    case .patternField(let pattern): "/\(pattern)/"
    case nil: "Schema"
    }
  }

  /// The items of an array whose row opens no card, such as `array of string`, and their items
  /// in turn for an array of arrays: their own constraints are shown here, since the diagram has
  /// nowhere to show them.
  private var itemsWithoutCard: [SchemaNode] {
    guard node.array != nil, DiagramCards.cardPath(for: node, at: path) == nil else { return [] }
    var levels: [SchemaNode] = []
    var items = node
    while let array = items.array, array.prefixItems.isEmpty, let next = array.items {
      levels.append(next)
      items = next
    }
    return levels
  }

  private var flags: [String] {
    var flags: [String] = []
    if node.isDeprecated { flags.append("deprecated") }
    if node.isReadOnly { flags.append("read only") }
    if node.isWriteOnly { flags.append("write only") }
    return flags
  }

  @ViewBuilder private var valuesSection: some View {
    if node.defaultValue != nil || !node.examples.isEmpty {
      Section("Values") {
        if let value = node.defaultValue {
          LabeledContent("Default") { Text(value.shown).monospaced() }
        }
        ForEach(Array(node.examples.enumerated()), id: \.offset) { _, example in
          LabeledContent("Example") {
            Text(example.shown).monospaced().lineLimit(3).textSelection(.enabled)
          }
        }
      }
    }
  }
}

private struct ScalarSection: View {
  let scalar: ScalarSchema

  var body: some View {
    if scalar.format != nil || !scalar.patterns.isEmpty || scalar.allowedValues != nil {
      Section("Value") {
        if let format = scalar.format { LabeledContent("Format") { Text(format).monospaced() } }
        ForEach(scalar.patterns, id: \.self) { pattern in
          LabeledContent("Pattern") { Text(pattern).monospaced().textSelection(.enabled) }
        }
        if let values = scalar.allowedValues {
          LabeledContent("Allowed") {
            Text(values.map(\.shown).joined(separator: ", ")).monospaced()
              .textSelection(.enabled)
          }
        }
      }
    }
  }
}

/// The type, constraints and rules each item of an array must meet.
private struct ItemsSection: View {
  let items: SchemaNode
  /// 0 for the array's own items, 1 for their items, and so on.
  let depth: Int

  var body: some View {
    Section(
      depth == 0 ? "Each item" : "Items \(depth + 1) levels in"
    ) {
      LabeledContent("Type", value: items.typeDescription)
      if let scalar = items.scalar {
        if let format = scalar.format { LabeledContent("Format") { Text(format).monospaced() } }
        ForEach(scalar.patterns, id: \.self) { pattern in
          LabeledContent("Pattern") { Text(pattern).monospaced().textSelection(.enabled) }
        }
        if let values = scalar.allowedValues {
          LabeledContent("Allowed") {
            Text(values.map(\.shown).joined(separator: ", ")).monospaced()
          }
        }
      }
      ForEach(Array(items.rules.enumerated()), id: \.offset) { _, rule in
        Text(markdown: rule.text).foregroundStyle(Color.swangerAmber)
      }
      if let description = items.description { Text(markdown: description) }
    }
  }
}

private struct RootDetails: View {
  let root: RootSchema

  var body: some View {
    Form {
      Section {
        Text(root.name).font(.title3.bold())
        if let description = root.node.description { Text(markdown: description) }
      }
      Section("The \(root.direction.rawValue) body of") {
        ForEach(root.operations, id: \.self) { operation in
          LabeledContent {
            Text(operation.mediaType).foregroundStyle(.secondary)
          } label: {
            Text(operation.description).monospaced()
          }
        }
      }
      Section {
        LabeledContent("Fields", value: "\(root.stats.fields)")
        LabeledContent("Fragments", value: "\(root.stats.fragments)")
        LabeledContent("Rules", value: "\(root.stats.rules)")
        LabeledContent("Examples", value: "\(root.examples.count)")
      }
    }
    .formStyle(.grouped)
  }
}

private struct FragmentDetails: View {
  let fragment: Fragment
  let spec: Spec
  let store: SpecStore

  var body: some View {
    Form {
      Section {
        Text(fragment.name).font(.title3.bold()).foregroundStyle(Color.swangerViolet)
        if let description = fragment.node.description { Text(markdown: description) }
      }
      Section("Defined in") {
        Text(fragment.id.description).font(.callout.monospaced()).textSelection(.enabled)
      }
      UsedInSection(fragment: fragment.reference, spec: spec, store: store)
    }
    .formStyle(.grouped)
  }
}

/// Every root using a fragment, and each place in it, as links that show it there.
private struct UsedInSection: View {
  let fragment: FragmentRef
  let spec: Spec
  let store: SpecStore

  var body: some View {
    Section("Used in") {
      let usages = spec.fragmentIndex.usages(of: fragment)
      if usages.isEmpty {
        Text("No schema").foregroundStyle(.secondary)
      }
      ForEach(spec.fragmentIndex.roots(using: fragment), id: \.self) { id in
        if let root = spec.root(id) {
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              Button(root.name) { store.show(.root(id)) }.buttonStyle(.link)
              Spacer()
              if let use = spec.fragmentIndex.use(of: fragment, in: id) { UsageDot(use: use) }
            }
            ForEach(usages.filter { $0.root == id }, id: \.self) { usage in
              if !usage.path.isEmpty {
                Button {
                  store.reveal(usage.path, in: id)
                } label: {
                  Text(usage.via.map { "\(usage.path) in \($0.name)" } ?? usage.path.description)
                    .font(.caption.monospaced())
                }
                .buttonStyle(.link)
              }
            }
          }
        }
      }
    }
  }
}

private struct FragmentLink: View {
  let fragment: FragmentRef
  let spec: Spec
  let store: SpecStore

  var body: some View {
    if spec.fragment(at: fragment.id) != nil {
      Button {
        store.show(.fragment(fragment.id))
      } label: {
        Label(fragment.name, systemImage: "puzzlepiece")
      }
      .buttonStyle(.link)
      .foregroundStyle(Color.swangerViolet)
    } else {
      Text(fragment.name)
    }
  }
}

extension JSONValue {
  /// The value as the inspector shows it: ``literal`` without the backticks around arrays and
  /// objects, which are only for rule wording.
  fileprivate var shown: String {
    switch self {
    case .array, .object: description
    default: literal
    }
  }
}
