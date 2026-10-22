import SwangerCore
import SwiftUI

/// A card for each request schema, and which fragments each schema uses.
struct OverviewPage: View {
  let spec: Spec
  let store: SpecStore
  @AppStorage("overviewIncludesResponses") private var includesResponses = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 4) {
          Text(spec.title ?? spec.url.lastPathComponent).font(.largeTitle.bold())
          Text(summary).foregroundStyle(.secondary)
        }
        if spec.requestSchemas.isEmpty {
          Text("This spec has no request bodies with a JSON schema.")
            .foregroundStyle(.secondary)
        } else {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            ForEach(spec.requestSchemas) { root in
              RootCard(root: root) { store.show(.root(root.id)) }
            }
          }
        }
        usage
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var summary: String {
    func count(_ number: Int, _ noun: String) -> String {
      "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
    return [
      count(spec.requestSchemas.count, "request schema"),
      count(spec.responseSchemas.count, "response schema"),
      count(spec.fragments.count, "shared fragment"),
    ].joined(separator: " · ")
  }

  @ViewBuilder private var usage: some View {
    let columns = includesResponses ? spec.roots : spec.requestSchemas
    let fragments = spec.fragments.filter { fragment in
      columns.contains { spec.fragmentIndex.use(of: fragment.reference, in: $0.id) != nil }
    }
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Shared fragments").font(.title2.bold())
        Spacer()
        Toggle("Include responses", isOn: $includesResponses)
      }
      if fragments.isEmpty {
        Text("No shared fragments are used by these schemas.").foregroundStyle(.secondary)
      } else {
        UsageGrid(spec: spec, fragments: fragments, columns: columns, store: store)
        HStack(spacing: 14) {
          Label {
            Text("Used directly")
          } icon: {
            UsageDot(use: .direct)
          }
          Label {
            Text("Inside another fragment")
          } icon: {
            UsageDot(use: .nested)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}

private struct RootCard: View {
  let root: RootSchema
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: 8) {
        Text(root.name).font(.headline).lineLimit(1)
        Text(root.operations.map(\.description).joined(separator: ", "))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(2, reservesSpace: true)
        HStack(spacing: 14) {
          stat(root.stats.fields, "fields", color: .swangerTeal)
          stat(root.stats.fragments, "fragments", color: .swangerViolet)
          stat(root.stats.rules, "rules", color: .swangerAmber)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.background, in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10).strokeBorder(Color.swangerTeal.opacity(0.5))
      }
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
  }

  private func stat(_ number: Int, _ noun: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("\(number)").font(.title3.bold().monospacedDigit()).foregroundStyle(color)
      Text(noun).font(.caption).foregroundStyle(.secondary)
    }
  }
}

/// Rows of fragments, columns of schemas: a filled dot where a schema uses a fragment directly,
/// an outlined one where it's only inside another fragment.
private struct UsageGrid: View {
  let spec: Spec
  let fragments: [Fragment]
  let columns: [RootSchema]
  let store: SpecStore

  private static let cell: CGFloat = 26
  /// The longest a rotated column header gets; longer names are cut short, with the full name
  /// in a tooltip.
  private static let maxHeaderHeight: CGFloat = 260

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow(alignment: .bottom) {
          let headerHeight = headerHeight
          Color.clear.frame(width: 1, height: 1)
          ForEach(columns) { root in
            Text(root.name)
              .font(.caption)
              .lineLimit(1)
              .frame(width: headerHeight, alignment: .leading)
              .rotationEffect(.degrees(-90))
              .frame(width: Self.cell, height: headerHeight)
              .help(root.name)
          }
        }
        ForEach(fragments) { fragment in
          GridRow {
            Button(fragment.name) { store.show(.fragment(fragment.id)) }
              .buttonStyle(.link)
              .foregroundStyle(Color.swangerViolet)
              .lineLimit(1)
              .padding(.trailing, 12)
              .frame(maxWidth: 240, alignment: .leading)
            ForEach(columns) { root in
              cell(fragment, root)
            }
          }
          .frame(height: Self.cell)
          Divider().gridCellUnsizedAxes(.horizontal)
        }
      }
    }
  }

  /// Tall enough for the longest column name, up to `maxHeaderHeight`.
  private var headerHeight: CGFloat {
    let font = NSFont.preferredFont(forTextStyle: .caption1)
    let longest = columns.map { ($0.name as NSString).size(withAttributes: [.font: font]).width }
    return min(ceil(longest.max() ?? 0) + 4, Self.maxHeaderHeight)
  }

  @ViewBuilder private func cell(_ fragment: Fragment, _ root: RootSchema) -> some View {
    let usages = spec.fragmentIndex.usages(of: fragment.reference).filter { $0.root == root.id }
    Group {
      if let use = spec.fragmentIndex.use(of: fragment.reference, in: root.id) {
        UsageDot(use: use)
          .frame(width: Self.cell, height: Self.cell)
          .contentShape(Rectangle())
          .onTapGesture {
            if let first = usages.first(where: \.isDirect) ?? usages.first {
              store.reveal(first.path, in: root.id)
            }
          }
          .help(help(for: usages, of: fragment, in: root))
      } else {
        Color.clear.frame(width: Self.cell, height: Self.cell)
      }
    }
  }

  private func help(for usages: [FragmentUsage], of fragment: Fragment, in root: RootSchema)
    -> String
  {
    let paths = usages.map { usage in
      let path = usage.path.isEmpty ? root.name : "\(root.name) · \(usage.path)"
      return usage.via.map { "\(path), inside \($0.name)" } ?? path
    }
    return "\(fragment.name) in \(root.name):\n" + paths.joined(separator: "\n")
  }
}

/// Filled when a schema uses a fragment directly, outlined when only inside other fragments.
struct UsageDot: View {
  let use: FragmentIndex.Use
  var size: CGFloat = 9

  var body: some View {
    Group {
      switch use {
      case .direct: Circle().fill(Color.swangerViolet)
      case .nested: Circle().strokeBorder(Color.swangerViolet, lineWidth: 1.2)
      }
    }
    .frame(width: size, height: size)
  }
}
