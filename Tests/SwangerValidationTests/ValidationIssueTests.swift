import OrderedJSON
import SwangerCore
import Testing

@testable import SwangerValidation

/// What each kind of mistake is reported as: its type, where, and the message.
@Suite struct ValidationIssueTests {
  struct Case: CustomTestStringConvertible, Sendable {
    var operation: String
    var payload: String
    var issues: [String]

    var testDescription: String { "\(operation) \(payload)" }
  }

  static let card = #"{"type":"card","number":"4111111111111111"}"#

  static let fixtureCases = [
    Case(
      operation: "createPayment", payload: "{}",
      issues: [
        "/amount: Missing: `amount` is required",
        "/currency: Missing: `currency` is required",
        "/method: Missing: `method` is required",
      ]),
    Case(
      operation: "createPayment",
      payload: #"{"amount":"10","currency":"GBP","method":\#(card)}"#,
      issues: ["/amount: Wrong type: Must be an integer, not a string"]),
    Case(
      operation: "createPayment",
      payload: #"{"amount":0,"currency":"GBP","method":\#(card)}"#,
      issues: ["/amount: Out of range: Must be at least 1"]),
    Case(
      operation: "createPayment",
      payload: #"{"amount":1,"currency":"USD","method":\#(card)}"#,
      issues: [#"/currency: Not allowed value: Must be one of "GBP" or "EUR""#]),
    // A wrong type, not also a value that isn't allowed.
    Case(
      operation: "createPayment",
      payload: #"{"amount":1,"currency":5,"method":\#(card)}"#,
      issues: ["/currency: Wrong type: Must be a string, not a number"]),
    Case(
      operation: "createPayment",
      payload:
        #"{"amount":1,"currency":"GBP","method":\#(card),"reference":"inv-1","email":"ada"}"#,
      issues: [
        "/reference: Wrong format: Must match `^[A-Z]{3}-[0-9]+$`",
        "/email: Wrong format: Must be an email address",
      ]),
    // The discriminator matches no variant: the values it could have.
    Case(
      operation: "createPayment",
      payload: #"{"amount":1,"currency":"GBP","method":{"type":"cheque"}}"#,
      issues: [#"/method/type: Not allowed value: Must be one of "card" or "bank-transfer""#]),
    // The discriminator picks the variant whose issues are reported.
    Case(
      operation: "createPayment",
      payload: #"{"amount":1,"currency":"GBP","method":{"type":"card","number":41}}"#,
      issues: ["/method/number: Wrong type: Must be a string, not a number"]),
    Case(
      operation: "createPayment",
      payload:
        #"{"amount":1,"currency":"GBP","method":{"type":"bank-transfer","sortCode":"12-34-56","number":"1"}}"#,
      issues: [
        "/method/accountNumber: Missing: `accountNumber` is required",
        "/method/number: Unexpected field: `number` isn't allowed",
      ]),
    Case(
      operation: "createPayment",
      payload: #"{"amount":1,"currency":"GBP","method":"card"}"#,
      issues: ["/method: Wrong type: Must be an object, not a string"]),
    Case(
      operation: "createPayment",
      payload:
        #"{"amount":1,"currency":"GBP","method":\#(card),"metadata":{"a":1,"b":"x","c":"y"},"tip":1}"#,
      issues: [
        "/metadata: Out of range: Allows at most 2 fields",
        "/metadata/a: Wrong type: Must be a string, not a number",
        "/tip: Unexpected field: `tip` isn't allowed",
      ]),
    // In the order the payload gives its fields.
    Case(
      operation: "createPayment",
      payload: #"{"method":{"type":"card","number":"1"},"currency":"GBP","amount":"x"}"#,
      issues: [
        "/method/number: Out of range: Needs at least 16 characters",
        "/amount: Wrong type: Must be an integer, not a string",
      ]),
    // A condition branch with a description.
    Case(
      operation: "createRefund",
      payload: #"{"paymentId":"6f1c2a54-58b1-4a0e-9d7e-0b8f4e1f2c3d","status":"Rejected"}"#,
      issues: ["/reason: Missing: A rejected refund needs a reason."]),
    Case(
      operation: "createRefund",
      payload:
        #"{"paymentId":"6f1c2a54-58b1-4a0e-9d7e-0b8f4e1f2c3d","status":"Requested","notes":"x"}"#,
      issues: ["/reason: Missing: `reason` is required when `notes` is present"]),
    Case(
      operation: "createRefund",
      payload: #"{"paymentId":"nope","status":"Requested","amount":5}"#,
      issues: [
        "/: Rule not met: Mustn't have `amount`",
        "/paymentId: Wrong format: Must be a UUID",
      ]),
    Case(
      operation: "replaceTags",
      payload: #"[{"name":"a"},{"name":"a"},{"name":"b"},{"name":"c"}]"#,
      issues: [
        "/: Out of range: Allows at most 3 items",
        "/: Rule not met: Items must all be different",
      ]),
  ]

  @Test(arguments: fixtureCases)
  func fixture(_ item: Case) throws {
    let validator = try Fixtures.validator("payments/spec.yaml")
    let root = try validator.spec.root(item.operation)
    #expect(validator.issues(in: json(item.payload), for: root).map(\.description) == item.issues)
  }

  /// `operation` is the schema here.
  static let inlineCases = [
    Case(
      operation: #"{"oneOf":[{"type":"integer"},{"type":"number"}]}"#, payload: "1",
      issues: [
        "/: Rule not met: Matches more than one of the 2 options, but must match exactly one"
      ]),
    Case(
      operation: #"{"oneOf":[{"type":"integer"},{"type":"number"},{"type":"string"}]}"#,
      payload: "1",
      issues: ["/: Rule not met: Matches 2 of the 3 options, but must match exactly one"]),
    Case(
      operation: #"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#, payload: "true",
      issues: ["/: Wrong type: Must be a string or an integer, not a boolean"]),
    // Only fields missing: the fields it could have.
    Case(
      operation: #"{"oneOf":[{"required":["a"]},{"required":["b"]}]}"#, payload: "{}",
      issues: ["/a: Missing: Needs `a` or `b`"]),
    Case(
      operation: #"{"anyOf":[{"required":["a"]},{"required":["b","c"]}]}"#, payload: #"{"b":1}"#,
      issues: ["/a: Missing: Needs `a` or `c`"]),
    Case(
      operation: #"{"anyOf":[{"required":["a"]},{"required":["b","c"]}]}"#, payload: "{}",
      issues: ["/a: Missing: Needs `a` or both `b` and `c`"]),
    // Otherwise the variant with fewest issues, or the choice itself when they tie.
    Case(
      operation: #"{"oneOf":[{"properties":{"a":{"type":"string"}}},{"required":["b","c"]}]}"#,
      payload: #"{"a":1}"#,
      issues: ["/a: Wrong type: Must be a string, not a number"]),
    Case(
      operation: #"{"oneOf":[{"properties":{"a":{"type":"string"}}},{"required":["b"]}]}"#,
      payload: #"{"a":1}"#,
      issues: ["/: Rule not met: Must match exactly one of the 2 options"]),
    Case(
      operation: #"{"prefixItems":[{"type":"string"}],"items":false}"#, payload: #"["a",1]"#,
      issues: ["/1: Unexpected field: There are more items than allowed"]),
    Case(
      operation: #"{"properties":{"a":false,"b":{"allOf":[false]}}}"#, payload: #"{"a":1,"b":2}"#,
      issues: [
        "/a: Unexpected field: `a` isn't allowed",
        "/b: Unexpected field: `b` isn't allowed",
      ]),
    Case(operation: "false", payload: "1", issues: ["/: Rule not met: Nothing is allowed here"]),
    Case(
      operation: #"{"if":{"required":["a"]},"then":{"required":["b"]}}"#, payload: #"{"a":1}"#,
      issues: ["/b: Missing: `b` is required"]),
    Case(
      operation: #"{"type":"string","not":{"const":"x"},"minLength":2}"#, payload: #""x""#,
      issues: [
        #"/: Rule not met: Mustn't be "x""#,
        "/: Out of range: Needs at least 2 characters",
      ]),
    Case(
      operation: #"{"type":"array","contains":{"type":"integer"},"maxContains":1}"#,
      payload: "[1,2]",
      issues: ["/: Rule not met: Allows at most 1 item matching `contains`"]),
    Case(
      operation: #"{"propertyNames":{"pattern":"^[a-z]+$"}}"#, payload: #"{"A":1}"#,
      issues: ["/: Rule not met: Field names must match `propertyNames`"]),
    Case(
      operation: #"{"type":"number","multipleOf":0.5,"exclusiveMaximum":10}"#, payload: "10.2",
      issues: [
        "/: Out of range: Must be a multiple of 0.5",
        "/: Out of range: Must be less than 10",
      ]),
    Case(
      operation: #"{"type":"object","properties":{"a~b/c":{"type":"string"}}}"#,
      payload: #"{"a~b/c":1}"#,
      issues: ["/a~0b~1c: Wrong type: Must be a string, not a number"]),
  ]

  @Test(arguments: inlineCases)
  func inline(_ item: Case) throws {
    let (validator, root) = try Fixtures.inline(item.operation)
    #expect(validator.issues(in: json(item.payload), for: root).map(\.description) == item.issues)
  }
}
