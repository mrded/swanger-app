import Foundation
import Observation
import OrderedJSON
import SwangerCore
import SwangerValidation

/// A Try it page's payload, checked against its schema as it's typed.
@MainActor @Observable
final class TryItModel {
  /// What checking the payload found.
  enum Outcome: Equatable {
    case checking
    case valid
    case invalid([TryItIssue])
    /// The text isn't JSON. The range is where the parser stopped.
    case syntaxError(message: String, line: Int, column: Int, range: Range<Int>)
  }

  let schema: TryItSchema
  let specURL: URL
  var text: String {
    didSet {
      guard text != oldValue else { return }
      // Straight away, so a page left before the check still finds it when it's back.
      TryItDrafts.save(text, for: schema, in: specURL)
      check()
    }
  }
  private(set) var outcome = Outcome.checking
  /// A range for the editor to select, counted so selecting the same range again still does.
  private(set) var selectionRequest = SelectionRequest(range: 0..<0, count: 0)

  @ObservationIgnored private var node: SchemaNode
  @ObservationIgnored private var validator: PayloadValidator
  @ObservationIgnored private var checkTask: Task<Void, Never>?

  init(
    schema: TryItSchema, node: SchemaNode, validator: PayloadValidator, specURL: URL,
    initialText: String
  ) {
    self.schema = schema
    self.node = node
    self.validator = validator
    self.specURL = specURL
    text = TryItDrafts.draft(for: schema, in: specURL) ?? initialText
    check(after: .zero)
  }

  /// After a reload: checks the payload again, against the schema as it is now.
  func update(node: SchemaNode, validator: PayloadValidator) {
    guard validator !== self.validator else { return }
    self.node = node
    self.validator = validator
    check(after: .zero)
  }

  /// Selects where `issue` is in the text as it is now, which can have changed since it was
  /// checked. When it isn't JSON now, where it was.
  func select(_ issue: TryItIssue) {
    select(JSONSourceMap(text)?.selection(for: issue.issue.pointer) ?? issue.range)
  }

  func select(_ range: Range<Int>) {
    selectionRequest = SelectionRequest(range: range, count: selectionRequest.count + 1)
  }

  /// Checks the payload after a pause in typing.
  private func check(after delay: Duration = .milliseconds(300)) {
    checkTask?.cancel()
    let text = text
    let (schema, node, validator) = (schema, node, validator)
    let location: NodeLocation =
      switch schema {
      case .root(let id): id.location
      case .fragment(let id): id
      }
    checkTask = Task {
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      // The last outcome stays until this one is ready, so the issue list doesn't flicker.
      let outcome = await LargeStack.run {
        Self.check(text, against: node, at: location, with: validator)
      }
      guard !Task.isCancelled else { return }
      self.outcome = outcome
    }
  }

  private nonisolated static func check(
    _ text: String, against node: SchemaNode, at location: NodeLocation,
    with validator: PayloadValidator
  ) -> Outcome {
    let payload: JSONValue
    do {
      payload = try JSONValue.parse(text)
    } catch let error as JSONParseError {
      let offset = JSONSourceMap.offset(utf8Offset: error.byteOffset, in: text)
      let end = min(offset + 1, text.utf16.count)
      return .syntaxError(
        message: error.message, line: error.line, column: error.column, range: offset..<end)
    } catch {
      return .syntaxError(
        message: String(describing: error), line: 1, column: 1, range: 0..<0)
    }
    let issues = validator.issues(in: payload, forSchemaAt: location)
    guard !issues.isEmpty else { return .valid }
    let map = JSONSourceMap(text)
    return .invalid(
      issues.enumerated().map { index, issue in
        TryItIssue(
          id: index, issue: issue, range: map?.selection(for: issue.pointer) ?? 0..<0,
          path: node.path(to: issue.pointer, in: payload))
      })
  }
}

/// A range for the editor to select. `count` tells one request from the next.
struct SelectionRequest: Equatable {
  var range: Range<Int>
  var count: Int
}

/// An issue, with where it is in the text and in the diagram.
struct TryItIssue: Identifiable, Equatable {
  let id: Int
  let issue: ValidationIssue
  /// UTF-16 offsets into the text that was checked.
  let range: Range<Int>
  /// The nearest row the schema has for the issue's value.
  let path: FieldPath
}
