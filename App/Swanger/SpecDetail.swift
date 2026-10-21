import SwangerCore
import SwiftUI

/// The page for the sidebar's selection.
///
/// These are plain summaries for now; task 9 of the plan replaces them with the overview grid and
/// the diagram.
struct SpecDetail: View {
  let spec: Spec
  let selection: SidebarItem

  var body: some View {
    switch selection {
    case .overview:
      OverviewSummary(spec: spec)
    case .root(let id):
      if let root = spec.root(id) {
        RootSummary(root: root)
      } else {
        missing
      }
    case .fragment(let id):
      if let fragment = spec.fragments.first(where: { $0.id == id }) {
        FragmentSummary(fragment: fragment, spec: spec)
      } else {
        missing
      }
    }
  }

  private var missing: some View {
    ContentUnavailableView(
      "Not in this spec any more", systemImage: "questionmark.square.dashed",
      description: Text("It was removed or renamed when the file changed."))
  }
}

private struct OverviewSummary: View {
  let spec: Spec

  var body: some View {
    Form {
      Section {
        LabeledContent("Title", value: spec.title ?? "—")
        LabeledContent("API version", value: spec.apiVersion ?? "—")
        LabeledContent("OpenAPI", value: spec.declaredVersion)
        LabeledContent("Files", value: "\(spec.referencedFiles.count)")
      }
      Section {
        LabeledContent("Request schemas", value: "\(spec.requestSchemas.count)")
        LabeledContent("Response schemas", value: "\(spec.responseSchemas.count)")
        LabeledContent("Shared fragments", value: "\(spec.fragments.count)")
      }
    }
    .formStyle(.grouped)
  }
}

private struct RootSummary: View {
  let root: RootSchema

  var body: some View {
    Form {
      Section { Text(root.name).font(.title2.bold()) }
      Section("Used as the \(root.direction.rawValue) body of") {
        ForEach(root.operations, id: \.self) { operation in
          LabeledContent(operation.description, value: operation.mediaType)
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

private struct FragmentSummary: View {
  let fragment: Fragment
  let spec: Spec

  var body: some View {
    Form {
      Section { Text(fragment.name).font(.title2.bold()) }
      Section("Defined in") {
        Text(fragment.id.description).font(.body.monospaced()).textSelection(.enabled)
      }
      Section("Used in") {
        ForEach(spec.fragmentIndex.roots(using: fragment.reference), id: \.self) { id in
          if let root = spec.root(id) {
            LabeledContent(root.name) {
              Text(
                spec.fragmentIndex.use(of: fragment.reference, in: id) == .direct
                  ? "directly" : "nested")
            }
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}
