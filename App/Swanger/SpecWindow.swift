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
      .frame(minHeight: 500)
      .task { store.start() }
      // The store outlives a rename or move, so it's told where the file went.
      .onChange(of: url) { _, url in store.fileMoved(to: url) }
      .onDisappear { store.stop() }
      .focusedSceneValue(\.specStore, store)
      .background(SwipeNavigation(store: store))
  }

  @ViewBuilder private var content: some View {
    if let spec = store.spec {
      #if APPSTORE
        if spec.referencedFiles.contains(where: { $0 != url.absoluteURL.standardizedFileURL }) {
          ContentUnavailableView(
            "Spec not supported",
            systemImage: "doc.badge.ellipsis",
            description: Text(
              "This spec references external files, which isn't supported in the Mac App Store version of Swanger. Consolidate your spec into a single file to use it here."
            ))
        } else {
          specContent(spec: spec)
        }
      #else
        specContent(spec: spec)
      #endif
    } else if let error = store.loadError {
      LoadErrorView(error: error, isLoading: store.isLoading) { store.reload() }
    } else {
      ProgressView("Loading \(store.url.lastPathComponent)…")
    }
  }

  @ViewBuilder private func specContent(spec: Spec) -> some View {
    NavigationSplitView {
      SpecSidebar(spec: spec, store: store)
        .navigationSplitViewColumnWidth(min: 200, ideal: 260)
    } detail: {
      SpecDetail(spec: spec, store: store)
        .safeAreaInset(edge: .top, spacing: 0) {
          if let error = store.loadError {
            ReloadFailedBanner(error: error) { store.reload() }
          }
        }
    }
    .inspector(isPresented: $showsInspector) {
      InspectorView(spec: spec, store: store)
        .inspectorColumnWidth(min: 240, ideal: 300)
    }
    .navigationSubtitle(subtitle(of: spec))
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button {
          store.goBack()
        } label: {
          Label("Back", systemImage: "chevron.backward")
        }
        .disabled(!store.history.canGoBack)
        .help("Go back")
        Button {
          store.goForward()
        } label: {
          Label("Forward", systemImage: "chevron.forward")
        }
        .disabled(!store.history.canGoForward)
        .help("Go forward")
      }
      ToolbarItem(placement: .principal) {
        Picker("View", selection: Binding(get: { store.mode }, set: { store.show($0) })) {
          Text("Diagram").tag(DetailMode.diagram)
          Text("Try it").tag(DetailMode.tryIt)
        }
        .pickerStyle(.segmented)
        .disabled(store.view.page == .overview)
        .help("Show the schema as a diagram, or check a payload against it")
      }
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
  }

  /// `OpenAPI 3.1.0 · Shop API 1.2`.
  private func subtitle(of spec: Spec) -> String {
    let api = [spec.title, spec.apiVersion].compactMap(\.self).joined(separator: " ")
    return ["OpenAPI \(spec.declaredVersion)", api].filter { !$0.isEmpty }
      .joined(separator: " · ")
  }
}
