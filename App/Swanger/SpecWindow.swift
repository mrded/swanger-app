import SwangerCore
import SwiftUI

/// A document window: the sidebar, the selected page and the inspector, or why the spec didn't
/// load.
struct SpecWindow: View {
  let url: URL
  @State private var store: SpecStore
  @State private var showsInspector = false

  init(url: URL) {
    self.url = url
    _store = State(initialValue: SpecStore(url: url))
  }

  var body: some View {
    content
      .frame(minWidth: 800, minHeight: 500)
      .task { store.start() }
      // The store outlives a rename or move, so it's told where the file went.
      .onChange(of: url) { _, url in store.fileMoved(to: url) }
      .onDisappear { store.stop() }
  }

  @ViewBuilder private var content: some View {
    if let spec = store.spec {
      NavigationSplitView {
        SpecSidebar(spec: spec, store: store)
          .navigationSplitViewColumnWidth(min: 200, ideal: 260)
      } detail: {
        SpecDetail(spec: spec, selection: store.selection ?? .overview)
          .safeAreaInset(edge: .top, spacing: 0) {
            if let error = store.loadError {
              ReloadFailedBanner(error: error) { store.reload() }
            }
          }
      }
      .inspector(isPresented: $showsInspector) {
        InspectorPlaceholder()
          .inspectorColumnWidth(min: 220, ideal: 280)
      }
      .navigationSubtitle(subtitle(of: spec))
      .toolbar {
        if !spec.warnings.isEmpty {
          ToolbarItem { WarningsButton(warnings: spec.warnings) }
        }
        ToolbarItem {
          Button {
            showsInspector.toggle()
          } label: {
            Label("Inspector", systemImage: "sidebar.trailing")
          }
          .help(showsInspector ? "Hide the inspector" : "Show the inspector")
        }
      }
    } else if let error = store.loadError {
      LoadErrorView(error: error, isLoading: store.isLoading) { store.reload() }
    } else {
      ProgressView("Loading \(store.url.lastPathComponent)…")
    }
  }

  /// `OpenAPI 3.1.0 · Shop API 1.2`.
  private func subtitle(of spec: Spec) -> String {
    let api = [spec.title, spec.apiVersion].compactMap(\.self).joined(separator: " ")
    return ["OpenAPI \(spec.declaredVersion)", api].filter { !$0.isEmpty }
      .joined(separator: " · ")
  }
}

/// Shown until task 9 gives the inspector its field details.
private struct InspectorPlaceholder: View {
  var body: some View {
    ContentUnavailableView(
      "No Selection", systemImage: "sidebar.trailing",
      description: Text("Select a field to see its details."))
  }
}
