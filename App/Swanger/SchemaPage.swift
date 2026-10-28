import SwangerCore
import SwiftUI

/// A request or response schema, or a shared fragment, as a diagram.
struct SchemaPage: View {
  let title: String
  let node: SchemaNode
  /// Under the title: the operations using a root, or where a fragment is used.
  let subtitle: String
  let tryIt: TryItSchema
  /// Try it's examples, and what it starts from without them.
  let examples: [TryItExample]
  let skeleton: String
  let store: SpecStore

  var body: some View {
    Group {
      switch store.mode {
      case .diagram:
        diagram
      case .tryIt:
        TryItView(
          schema: tryIt, node: node, examples: examples, skeleton: skeleton, store: store)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) { header(focus: store.mode == .diagram ? focus : nil) }
  }

  /// The card shown on its own. A reload can remove it; then the whole schema is shown.
  private var focus: FieldPath? {
    store.view.diagram.focus.flatMap { node.node(at: $0) != nil ? $0 : nil }
  }

  @ViewBuilder private var diagram: some View {
    let state = store.view.diagram
    let focus = focus
    let cards = DiagramCards.cards(
      of: node, title: focus.map(title(of:)) ?? title, from: focus ?? FieldPath(),
      open: state.openRows)
    DiagramView(
      cards: cards, state: state, savedViewport: store.view.viewport,
      restoreCount: store.restoreCount, reveal: store.pendingReveal,
      didReveal: store.revealed,
      viewportChanged: { store.liveViewport = $0 },
      selectRow: select, showsInspector: store.showsInspector,
      toggleInspector: toggleInspector, openOnItsOwn: openOnItsOwn,
      clearSelection: { store.select(nil) }
    )
  }

  private func header(focus: FieldPath?) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.title3.bold())
        Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      if let focus {
        Text("Showing `\(focus.description)` on its own").font(.callout)
          .foregroundStyle(.secondary)
        Button("Show the whole schema") {
          store.changeDiagram(resettingViewport: true) { $0.focus = nil }
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  /// The last part of the path, as the card's title.
  private func title(of path: FieldPath) -> String {
    let named = path.components.last(where: { $0 != .items })
    let items = path.components.reversed().prefix { $0 == .items }.count
    let base: String =
      switch named {
      case .field(let name), .variant(let name, _): name
      case .prefixItem(let index): "[\(index)]"
      case .otherFields: "other fields"
      case .patternField(let pattern): "/\(pattern)/"
      case .items, nil: title
      }
    return base + String(repeating: "[]", count: items)
  }

  /// Selects the row and opens or closes its card. Opening and closing are moves in the
  /// history; selecting alone isn't.
  private func select(_ row: CardRow) {
    guard let path = row.path else { return }
    if row.opens == nil {
      store.select(path)
      return
    }
    store.changeDiagram { diagram in
      let isOpen = diagram.openRows.contains(path)
      if isOpen && diagram.selection == path {
        diagram.openRows.remove(path)
      } else {
        diagram.openRows.insert(path)
      }
      diagram.selection = path
    }
  }

  /// Selects the row, without opening or closing its card, and shows or hides the inspector.
  private func toggleInspector(for row: CardRow) {
    guard let path = row.path else { return }
    if !store.showsInspector { store.select(path) }
    store.showsInspector.toggle()
  }

  /// A fragment opens its own page; any other card is shown alone.
  private func openOnItsOwn(_ card: DiagramCard) {
    if let fragment = card.node.fragment, store.view.page != .fragment(fragment.id),
      store.spec?.fragment(at: fragment.id) != nil
    {
      store.show(.fragment(fragment.id))
      return
    }
    guard !card.id.isEmpty else { return }
    store.changeDiagram(resettingViewport: true) { $0.focus = card.id }
  }
}
