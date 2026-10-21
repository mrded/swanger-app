import CoreGraphics
import SwangerCore

/// A page the detail column shows.
enum Page: Hashable {
  case overview
  case root(RootID)
  case fragment(NodeLocation)
}

/// What the sidebar can select: a page, or a field found by searching.
enum SidebarItem: Hashable {
  case page(Page)
  case field(RootID, FieldPath)
}

/// How far the diagram is zoomed, and where it's panned to.
struct Viewport: Equatable {
  static let initial = Viewport(scale: 1, offset: CGSize(width: 24, height: 24))

  var scale: CGFloat
  /// Where the diagram's top left corner is, in the view.
  var offset: CGSize
}

/// What a schema page shows: the cards that are open, the card shown on its own and the
/// selected row. Paths are from the page's schema.
struct DiagramState: Equatable {
  /// Rows whose cards are open.
  var openRows: Set<FieldPath> = []
  /// The card shown on its own, without the cards around it.
  var focus: FieldPath?
  /// The selected row, whose details the inspector shows.
  var selection: FieldPath?
  /// A row found by searching, scrolled into view and marked until the next move.
  var highlight: FieldPath?
}

extension DiagramState {
  /// Selects and marks the row at `path`, with every card on the way to it open.
  mutating func show(_ path: FieldPath) {
    openRows.formUnion(path.prefixes)
    // A card shown on its own holds the rows strictly inside it; its own row is in its parent.
    if let focus, path == focus || !path.components.starts(with: focus.components) {
      self.focus = nil
    }
    selection = path
    highlight = path
  }
}

/// What a schema page shows.
enum DetailMode: Hashable {
  case diagram
  case tryIt
}

/// One entry in the window's history.
struct ViewState: Equatable {
  var page: Page
  var diagram = DiagramState()
  /// Where the diagram was when the window moved on. `nil` until then, for the initial viewport.
  var viewport: Viewport?
}

/// Back and forward through a window's moves, as in a browser.
struct History {
  private(set) var current: ViewState
  private var back: [ViewState] = []
  private var forward: [ViewState] = []

  init(_ start: ViewState) {
    current = start
  }

  var canGoBack: Bool { !back.isEmpty }
  var canGoForward: Bool { !forward.isEmpty }

  /// Makes `state` the current entry, keeping the one it replaces to go back to.
  mutating func move(to state: ViewState, leaving viewport: Viewport?) {
    guard state != current else { return }
    var left = current
    left.viewport = viewport ?? left.viewport
    back.append(left)
    forward.removeAll()
    current = state
  }

  /// Changes the current entry without adding one, such as a selection that opens nothing.
  mutating func replace(with state: ViewState) {
    current = state
  }

  /// Whether there was an entry to go back to.
  @discardableResult
  mutating func goBack(leaving viewport: Viewport?) -> Bool {
    guard let previous = back.popLast() else { return false }
    var left = current
    left.viewport = viewport ?? left.viewport
    forward.append(left)
    current = previous
    return true
  }

  /// Whether there was an entry to go forward to.
  @discardableResult
  mutating func goForward(leaving viewport: Viewport?) -> Bool {
    guard let next = forward.popLast() else { return false }
    var left = current
    left.viewport = viewport ?? left.viewport
    back.append(left)
    current = next
    return true
  }

  /// Drops entries for pages `keep` says are gone, after a reload.
  mutating func prune(keeping keep: (Page) -> Bool) {
    back.removeAll { !keep($0.page) }
    forward.removeAll { !keep($0.page) }
    if !keep(current.page) { current = ViewState(page: .overview) }
  }
}

extension FieldPath {
  /// Every path from the first component to this one, shortest first.
  var prefixes: [FieldPath] {
    components.indices.map { FieldPath(Array(components[...$0])) }
  }

  /// The path without its last component.
  var parent: FieldPath? {
    isEmpty ? nil : FieldPath(Array(components.dropLast()))
  }
}
