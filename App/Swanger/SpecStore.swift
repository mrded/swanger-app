import Foundation
import Observation
import SwangerCore

/// What the sidebar can select.
enum SidebarItem: Hashable {
  case overview
  case root(RootID)
  case fragment(NodeLocation)
}

/// One window's spec: loads it in the background, reloads it when it or a file it refers to
/// changes, and keeps the window's selection.
@MainActor @Observable
final class SpecStore {
  let url: URL
  /// The latest spec that loaded. A failed reload keeps the previous one.
  private(set) var spec: Spec?
  /// Why the latest load failed. With a ``spec``, it's shown as a banner over the old model.
  private(set) var loadError: LoadError?
  private(set) var isLoading = false
  var selection: SidebarItem? = .overview
  var searchText = ""

  @ObservationIgnored private var watcher: FileWatcher?
  @ObservationIgnored private var loadTask: Task<Void, Never>?

  init(url: URL) {
    self.url = url
  }

  /// Loads the spec now and again whenever its files change.
  func start() {
    if spec == nil && loadTask == nil { reload() }
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
    loadTask = Task {
      let result = await Task.detached(priority: .userInitiated) {
        Result { () throws(LoadError) in try Spec.load(url) }
      }.value
      guard !Task.isCancelled else { return }
      apply(result)
    }
  }

  private func apply(_ result: Result<Spec, LoadError>) {
    isLoading = false
    switch result {
    case .success(let spec):
      self.spec = spec
      loadError = nil
      if let selection, !spec.contains(selection) { self.selection = .overview }
    case .failure(let error):
      loadError = error
    }
    watch(spec?.referencedFiles ?? [])
  }

  /// Watches the spec and `files`, replacing the watcher only when the list changes.
  private func watch(_ files: [URL]) {
    let urls = [url] + files
    let standardized = Set(urls.map(\.standardizedFileURL))
    if let watcher, Set(watcher.urls) == standardized { return }
    watcher?.cancel()
    watcher = FileWatcher(urls: urls) { [weak self] in
      Task { @MainActor in self?.reload() }
    }
  }
}

extension Spec {
  func contains(_ item: SidebarItem) -> Bool {
    switch item {
    case .overview: true
    case .root(let id): root(id) != nil
    case .fragment(let id): fragments.contains { $0.id == id }
    }
  }
}
