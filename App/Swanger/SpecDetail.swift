import OrderedJSON
import SwangerCore
import SwangerValidation
import SwiftUI

/// The page the window is on: the overview, or a schema's diagram.
struct SpecDetail: View {
  let spec: Spec
  let store: SpecStore

  var body: some View {
    switch store.view.page {
    case .overview:
      OverviewPage(spec: spec, store: store)
    case .root(let id):
      if let root = spec.root(id) {
        SchemaPage(
          title: root.name, node: root.node,
          subtitle: root.operations.map(\.description).joined(separator: " · "),
          tryIt: .root(id),
          examples: Self.examples(
            root.examples.map(\.value), named: ExampleNames.names(for: root.examples, of: root.node)
          ),
          skeleton: Self.text(Skeleton.payload(for: root.node, in: spec)), store: store
        )
        .id(store.view.page)
      } else {
        missing
      }
    case .fragment(let id):
      if let fragment = spec.fragment(at: id) {
        SchemaPage(
          title: fragment.name, node: fragment.node, subtitle: usedIn(fragment),
          tryIt: .fragment(id),
          examples: Self.examples(
            fragment.node.examples,
            named: ExampleNames.names(for: fragment.node.examples, of: fragment.node)),
          skeleton: Self.text(Skeleton.payload(for: fragment.node, in: spec)), store: store
        )
        .id(store.view.page)
      } else {
        missing
      }
    }
  }

  /// `Shared fragment, used by 3 schemas`.
  private func usedIn(_ fragment: Fragment) -> String {
    let count = spec.fragmentIndex.roots(using: fragment.reference).count
    return "Shared fragment, used by \(count) schema\(count == 1 ? "" : "s")"
  }

  private static func examples(_ values: [JSONValue], named names: [String]) -> [TryItExample] {
    zip(values, names).enumerated().map { index, example in
      TryItExample(id: index, name: example.1, text: text(example.0))
    }
  }

  private static func text(_ value: JSONValue) -> String {
    value.prettyText
  }

  private var missing: some View {
    ContentUnavailableView(
      "Not in this spec any more", systemImage: "questionmark.square.dashed",
      description: Text("It was removed or renamed when the file changed."))
  }
}
