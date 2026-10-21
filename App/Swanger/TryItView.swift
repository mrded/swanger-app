import OrderedJSON
import SwangerCore
import SwangerValidation
import SwiftUI

/// A payload to check, one of the schema's examples or its skeleton.
struct TryItExample: Identifiable {
  let id: Int
  let name: String
  let text: String
}

/// Try it: a JSON editor checked against the page's schema as you type, with what's wrong
/// listed under it.
struct TryItView: View {
  let schema: TryItSchema
  let node: SchemaNode
  let examples: [TryItExample]
  let skeleton: String
  let store: SpecStore
  @State private var model: TryItModel?
  @State private var selectedIssue: TryItIssue.ID?

  var body: some View {
    if let validator = store.validator {
      content(validator: validator)
    } else {
      ProgressView()
    }
  }

  @ViewBuilder
  private func content(validator: PayloadValidator) -> some View {
    VStack(spacing: 0) {
      bar
      Divider()
      if let model {
        VSplitView {
          JSONEditor(
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            selectionRequest: model.selectionRequest
          )
          .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
          IssueList(
            outcome: model.outcome, selection: $selectedIssue, choose: choose,
            selectText: model.select
          )
          .frame(maxWidth: .infinity, minHeight: 80, idealHeight: 180)
          .onChange(of: model.outcome) { selectedIssue = nil }
        }
      }
    }
    .onAppear {
      if model == nil {
        model = TryItModel(
          schema: schema, node: node, validator: validator, specURL: store.url,
          initialText: examples.first?.text ?? skeleton)
      }
    }
    .onChange(of: ObjectIdentifier(validator)) { model?.update(node: node, validator: validator) }
  }

  private var bar: some View {
    HStack {
      Menu("Examples") {
        ForEach(examples) { example in
          Button(example.name) { model?.text = example.text }
        }
        if !examples.isEmpty { Divider() }
        Button("Required Fields Only") { model?.text = skeleton }
      }
      .menuStyle(.button)
      .fixedSize()
      .help("Replace the payload with an example")
      Spacer()
      if let outcome = model?.outcome { OutcomeLabel(outcome: outcome) }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  /// Selects the issue's text, and its row in the diagram.
  private func choose(_ issue: TryItIssue) {
    model?.select(issue)
    let row = DiagramCards.nearestRow(to: issue.path, in: node)
    if row.isEmpty {
      store.select(nil)
    } else {
      store.revealOnThisPage(row)
    }
  }
}

/// "Valid", "3 issues" or "Not JSON", by the examples menu.
private struct OutcomeLabel: View {
  let outcome: TryItModel.Outcome

  var body: some View {
    switch outcome {
    case .checking:
      ProgressView().controlSize(.small)
    case .valid:
      Label("Valid", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    case .invalid(let issues):
      Label(
        "\(issues.count) issue\(issues.count == 1 ? "" : "s")",
        systemImage: "exclamationmark.triangle.fill"
      )
      .foregroundStyle(Color.swangerAmber)
    case .syntaxError:
      Label("Not JSON", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
    }
  }
}

/// What's wrong with the payload, or that nothing is.
private struct IssueList: View {
  let outcome: TryItModel.Outcome
  @Binding var selection: TryItIssue.ID?
  let choose: (TryItIssue) -> Void
  let selectText: (Range<Int>) -> Void

  /// The syntax error's tag in the list, which no issue has.
  private static let syntaxErrorID = -1

  var body: some View {
    switch outcome {
    case .checking:
      Color.clear
    case .valid:
      ContentUnavailableView(
        "Valid", systemImage: "checkmark.circle",
        description: Text("The payload matches the schema."))
    case .invalid(let issues):
      List(issues, selection: $selection) { issue in
        IssueRow(issue: issue).tag(issue.id)
      }
      .onChange(of: selection) { _, id in
        if let issue = issues.first(where: { $0.id == id }) { choose(issue) }
      }
    case .syntaxError(let message, let line, let column, let range):
      List(selection: $selection) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Line \(line), column \(column)").font(.caption.weight(.semibold))
            .foregroundStyle(.red)
          Text(message)
        }
        .tag(Self.syntaxErrorID)
      }
      .onChange(of: selection) { _, id in
        if id == Self.syntaxErrorID { selectText(range) }
      }
    }
  }
}

private struct IssueRow: View {
  let issue: TryItIssue

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(issue.issue.kind.rawValue).font(.caption.weight(.semibold))
          .foregroundStyle(Color.swangerAmber)
        Text(issue.issue.pointer.isRoot ? "/" : issue.issue.pointer.description)
          .font(.caption.monospaced()).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      Text(markdown: issue.issue.message)
    }
    .padding(.vertical, 2)
  }
}
