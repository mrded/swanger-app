import SwangerCore
import SwiftUI

/// Overview, request schemas, response schemas and shared fragments, filtered by the search field.
struct SpecSidebar: View {
  let spec: Spec
  @Bindable var store: SpecStore

  var body: some View {
    List(selection: $store.selection) {
      if query.isEmpty {
        Label("Overview", systemImage: "square.grid.2x2").tag(SidebarItem.overview)
      }
      rootSection("Request schemas", roots: spec.requestSchemas, systemImage: "arrow.up.doc")
      rootSection("Response schemas", roots: spec.responseSchemas, systemImage: "arrow.down.doc")
      let fragments = spec.fragments.filter { matches($0.name) }
      if !fragments.isEmpty {
        Section("Shared fragments") {
          ForEach(fragments) { fragment in
            FragmentRow(fragment: fragment, spec: spec).tag(SidebarItem.fragment(fragment.id))
          }
        }
      }
    }
    .searchable(text: $store.searchText, placement: .sidebar, prompt: "Filter")
    .overlay {
      if !query.isEmpty && !hasMatches {
        ContentUnavailableView.search(text: query)
      }
    }
  }

  @ViewBuilder
  private func rootSection(
    _ title: String, roots: [RootSchema], systemImage: String
  ) -> some View {
    let roots = roots.filter { matches($0.name) }
    if !roots.isEmpty {
      Section(title) {
        ForEach(roots) { root in
          Label(root.name, systemImage: systemImage)
            .help(root.operations.map(\.description).joined(separator: "\n"))
            .tag(SidebarItem.root(root.id))
        }
      }
    }
  }

  private var query: String {
    store.searchText.trimmingCharacters(in: .whitespaces)
  }

  private func matches(_ name: String) -> Bool {
    query.isEmpty || name.localizedStandardContains(query)
  }

  private var hasMatches: Bool {
    spec.roots.contains { matches($0.name) } || spec.fragments.contains { matches($0.name) }
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
        switch use {
        case .direct: Circle().fill(.purple)
        case .nested: Circle().strokeBorder(.purple, lineWidth: 1.2)
        }
      }
      .frame(width: 7, height: 7)
      if uses.count > maximum {
        Text("+\(uses.count - maximum)").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Used by \(uses.count) schemas")
  }
}
