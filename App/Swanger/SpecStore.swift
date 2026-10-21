import Foundation
import Observation
import SwangerCore

/// One window's spec: loads it in the background, reloads it when it or a file it refers to
/// changes, and keeps the window's history of where it's been.
@MainActor @Observable
final class SpecStore {
  /// Where the spec is now. It changes when the document is renamed or moved.
  private(set) var url: URL
  /// The latest spec that loaded. A failed reload keeps the previous one.
  private(set) var spec: Spec?
  /// Finds roots, fragments and fields in ``spec``.
  private(set) var searchIndex: SearchIndex?
  /// Why the latest load failed. With a ``spec``, it's shown as a banner over the old model.
  private(set) var loadError: LoadError?
  private(set) var isLoading = false
  private(set) var history = History(ViewState(page: .overview))
  /// Counts moves back and forward, so the diagram puts back the viewport it had.
  private(set) var restoreCount = 0
  /// A row found by searching that the diagram should scroll to. Unlike the highlight, it isn't
  /// kept in the history, so going back to a search result puts back the viewport it had.
  private(set) var pendingReveal: FieldPath?
  /// Counts ⌘F presses, so the sidebar focuses its search field.
  private(set) var findCount = 0
  var searchText = ""

  /// Where the diagram is now. Kept out of observation since it changes as it's panned; saved
  /// into the history entry it belongs to when the window moves on.
  @ObservationIgnored var liveViewport: Viewport?

  @ObservationIgnored private var watcher: FileWatcher?
  @ObservationIgnored private var loadTask: Task<Void, Never>?

  init(url: URL) {
    self.url = url
  }

  /// Loads the spec now and again whenever its files change. Called each time the window appears,
  /// so after ``stop()`` it loads again, picking up edits made while nothing was watching.
  func start() {
    if watcher == nil && loadTask == nil { reload() }
  }

  /// Follows the document to its new place, and loads it from there.
  func fileMoved(to url: URL) {
    guard url != self.url else { return }
    self.url = url
    reload()
  }

  func stop() {
    loadTask?.cancel()
    loadTask = nil
    watcher?.cancel()
    watcher = nil
  }

  func reload() {
    loadTask?.cancel()
    isLoading = true
    let url = url
    let started = Date()
    loadTask = Task {
      let result = await Task.detached(priority: .userInitiated) {
        Result { () throws(LoadError) in
          let spec = try Spec.load(url)
          return (spec, SearchIndex(spec: spec))
        }
      }.value
      guard !Task.isCancelled else { return }
      apply(result, loadedAt: started)
    }
  }

  private func apply(_ result: Result<(Spec, SearchIndex), LoadError>, loadedAt started: Date) {
    isLoading = false
    switch result {
    case .success(let (spec, searchIndex)):
      self.spec = spec
      self.searchIndex = searchIndex
      loadError = nil
      history.prune { spec.contains($0) }
    case .failure(let error):
      loadError = error
    }
    watch(spec?.referencedFiles ?? [], readSince: started)
  }

  /// Watches the spec and `files`, replacing the watcher only when the list changes. A new watcher
  /// reloads straight away if a file changed after `started`, while it was being loaded unwatched.
  private func watch(_ files: [URL], readSince started: Date) {
    let urls = [url] + files
    let standardized = Set(urls.map(\.standardizedFileURL))
    if let watcher, Set(watcher.urls) == standardized { return }
    watcher?.cancel()
    watcher = FileWatcher(urls: urls, changedSince: started) { [weak self] in
      Task { @MainActor in self?.reload() }
    }
  }
}

// MARK: - Moving around

extension SpecStore {
  var view: ViewState { history.current }

  /// Shows `page` from the top, unless it's showing already.
  func show(_ page: Page) {
    guard page != view.page else { return }
    move(to: ViewState(page: page))
    restored()
  }

  /// Shows the field at `path` in a root, its cards open, selected and marked.
  func reveal(_ path: FieldPath, in root: RootID) {
    var state = view.page == .root(root) ? view : ViewState(page: .root(root))
    state.diagram.openRows.formUnion(path.prefixes)
    if let focus = state.diagram.focus, !path.components.starts(with: focus.components) {
      state.diagram.focus = nil
    }
    state.diagram.selection = path
    state.diagram.highlight = path
    let isNewPage = state.page != view.page
    move(to: state)
    if isNewPage { restored() }
    pendingReveal = path
  }

  /// The diagram has scrolled to ``pendingReveal``.
  func revealed() {
    pendingReveal = nil
  }

  /// Changes what the diagram shows, as a move that can be gone back from. A diagram that starts
  /// from a different card, such as a card shown on its own, starts from the initial viewport.
  func changeDiagram(resettingViewport: Bool = false, _ change: (inout DiagramState) -> Void) {
    var state = view
    change(&state.diagram)
    state.diagram.highlight = nil
    if resettingViewport { state.viewport = nil }
    move(to: state)
    if resettingViewport { restored() }
  }

  /// Selects a row, or nothing, without adding to the history.
  func select(_ path: FieldPath?) {
    var state = view
    state.diagram.selection = path
    state.diagram.highlight = nil
    history.replace(with: state)
  }

  /// Whether there was somewhere to go back to.
  @discardableResult
  func goBack() -> Bool {
    guard history.goBack(leaving: liveViewport) else { return false }
    restored()
    return true
  }

  /// Whether there was somewhere to go forward to.
  @discardableResult
  func goForward() -> Bool {
    guard history.goForward(leaving: liveViewport) else { return false }
    restored()
    return true
  }

  func find() {
    findCount += 1
  }

  /// The diagram, if the page has one, sets its viewport from the entry and reports it again.
  private func restored() {
    liveViewport = nil
    pendingReveal = nil
    restoreCount += 1
  }

  private func move(to state: ViewState) {
    history.move(to: state, leaving: liveViewport)
  }
}

extension Spec {
  func contains(_ page: Page) -> Bool {
    switch page {
    case .overview: true
    case .root(let id): root(id) != nil
    case .fragment(let id): fragments.contains { $0.id == id }
    }
  }

  func fragment(at id: NodeLocation) -> Fragment? {
    fragments.first { $0.id == id }
  }
}
