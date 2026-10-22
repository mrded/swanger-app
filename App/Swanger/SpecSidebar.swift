import SwangerCore
import SwiftUI

/// Overview, request schemas, response schemas and shared fragments; or, while searching, the
/// roots, fragments and fields that match, best first.
struct SpecSidebar: View {
  let spec: Spec
  @Bindable var store: SpecStore
  @FocusState private var isSearchFocused: Bool
  // Per window, so each open spec keeps its own folds.
  @SceneStorage("sidebarRequestsExpanded") private var requestsExpanded = true
  @SceneStorage("sidebarResponsesExpanded") private var responsesExpanded = true
  @SceneStorage("sidebarFragmentsExpanded") private var fragmentsExpanded = true

  var body: some View {
    List(selection: selection) {
      if query.isEmpty {
        Label("Overview", systemImage: "square.grid.2x2").tag(SidebarItem.page(.overview))
        rootSection("Request schemas", roots: spec.requestSchemas, isExpanded: $requestsExpanded)
        rootSection(
          "Response schemas", roots: spec.responseSchemas, isExpanded: $responsesExpanded)
        if !spec.fragments.isEmpty {
          Section("Shared fragments", isExpanded: $fragmentsExpanded) {
            ForEach(spec.fragments) { fragment in
              FragmentRow(fragment: fragment, spec: spec)
                .tag(SidebarItem.page(.fragment(fragment.id)))
            }
          }
        }
      } else {
        ForEach(results, id: \.self) { result in
          SearchResultRow(result: result, spec: spec).tag(item(for: result.target))
        }
      }
    }
    .searchable(text: $store.searchText, placement: .sidebar, prompt: "Fields, schemas, fragments")
    .searchFocused($isSearchFocused)
    .onChange(of: store.findCount) { isSearchFocused = true }
    .overlay {
      if !query.isEmpty && results.isEmpty {
        ContentUnavailableView.search(text: query)
      }
    }
  }

  /// The current page, or the field found by searching that's showing.
  private var selection: Binding<SidebarItem?> {
    Binding {
      if !query.isEmpty, case .root(let id) = store.view.page,
        let highlight = store.view.diagram.highlight
      {
        return .field(id, highlight)
      }
      return .page(store.view.page)
    } set: { item in
      switch item {
      case .page(let page): store.show(page)
      case .field(let root, let path): store.reveal(path, in: root)
      case nil: break
      }
    }
  }

  private func rootSection(_ title: String, roots: [RootSchema], isExpanded: Binding<Bool>)
    -> some View
  {
    Section(title, isExpanded: isExpanded) {
      ForEach(roots) { root in
        Label(root.name, systemImage: root.direction.systemImage)
          .help(root.operations.map(\.description).joined(separator: "\n"))
          .tag(SidebarItem.page(.root(root.id)))
      }
    }
  }

  private var query: String {
    store.searchText.trimmingCharacters(in: .whitespaces)
  }

  private var results: [SearchIndex.Result] {
    store.searchIndex?.search(query) ?? []
  }

  private func item(for target: SearchIndex.Result.Target) -> SidebarItem {
    switch target {
    case .root(let id): .page(.root(id))
    case .fragment(let fragment): .page(.fragment(fragment.id))
    case .field(let root, let path): .field(root, path)
    }
  }
}

private struct SearchResultRow: View {
  let result: SearchIndex.Result
  let spec: Spec

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 1) {
        Text(result.name).lineLimit(1)
        if let detail = result.detail {
          Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .truncationMode(.head)
        }
      }
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(isFragment ? Color.swangerViolet : .secondary)
    }
  }

  private var isFragment: Bool {
    if case .fragment = result.target { true } else { false }
  }

  private var systemImage: String {
    switch result.target {
    case .root(let id): id.direction.systemImage
    case .fragment: "puzzlepiece"
    case .field: "text.alignleft"
    }
  }
}

extension RootSchema.Direction {
  var systemImage: String {
    switch self {
    case .request: "arrow.up.doc"
    case .response: "arrow.down.doc"
    }
  }
}

/// A fragment's name, with a dot for each schema using it: filled when the schema uses it
/// directly, outlined when only through other fragments.
private struct FragmentRow: View {
  let fragment: Fragment
  let spec: Spec

  private static let maximumDots = 6

  var body: some View {
    let uses = spec.fragmentIndex.roots(using: fragment.reference).compactMap { root in
      spec.fragmentIndex.use(of: fragment.reference, in: root)
    }
    HStack {
      Label(fragment.name, systemImage: "puzzlepiece")
      Spacer()
      UsageDots(uses: uses, maximum: Self.maximumDots)
    }
    .help(help(for: uses))
  }

  private func help(for uses: [FragmentIndex.Use]) -> String {
    let direct = uses.count { $0 == .direct }
    let nested = uses.count - direct
    func schemas(_ count: Int) -> String { count == 1 ? "1 schema" : "\(count) schemas" }
    var parts: [String] = []
    if direct > 0 { parts.append("Used directly by \(schemas(direct))") }
    if nested > 0 { parts.append("inside other fragments in \(schemas(nested))") }
    return parts.isEmpty ? "Not used by any schema" : parts.joined(separator: ", ")
  }
}

private struct UsageDots: View {
  let uses: [FragmentIndex.Use]
  let maximum: Int

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(uses.prefix(maximum).enumerated()), id: \.offset) { _, use in
        UsageDot(use: use, size: 7)
      }
      if uses.count > maximum {
        Text("+\(uses.count - maximum)").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Used by \(uses.count) schemas")
  }
}
