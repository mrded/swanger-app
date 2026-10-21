import OrderedJSON
import SwangerCore
import Testing

@testable import SwangerValidation

@Suite struct ExampleNamesTests {
  static let card = #""method":{"type":"card","number":"4111111111111111"}"#
  static let bank =
    #""method":{"type":"bank-transfer","sortCode":"12-34-56","accountNumber":"12345678"}"#

  @Test(arguments: [
    // Fixed values first.
    (
      [#"{"amount":1,"currency":"GBP",\#(card)}"#, #"{"amount":1,"currency":"EUR",\#(card)}"#],
      ["currency: GBP", "currency: EUR"]
    ),
    // Then which optional fields are there.
    (
      [
        #"{"amount":1,"currency":"GBP",\#(card)}"#,
        #"{"amount":1,"currency":"GBP","reference":"A-1",\#(card)}"#,
      ],
      ["without reference", "with reference"]
    ),
    // Then the same one level down: the discriminator of `method`.
    (
      [#"{"amount":1,"currency":"GBP",\#(card)}"#, #"{"amount":1,"currency":"GBP",\#(bank)}"#],
      ["method.type: card", "method.type: bank-transfer"]
    ),
    // Then the shortest value that differs.
    (
      [
        #"{"amount":10,"currency":"GBP","email":"ada@example.com",\#(card)}"#,
        #"{"amount":2500,"currency":"GBP","email":"grace@example.com",\#(card)}"#,
      ],
      ["amount: 10", "amount: 2500"]
    ),
    // Each step only names what the steps before it couldn't tell apart.
    (
      [
        #"{"amount":1,"currency":"GBP",\#(card)}"#,
        #"{"amount":1,"currency":"GBP","reference":"A-1",\#(card)}"#,
        #"{"amount":1,"currency":"EUR",\#(card)}"#,
      ],
      ["currency: GBP, without reference", "currency: GBP, with reference", "currency: EUR"]
    ),
    ([#"{"amount":1}"#], ["Example"]),
    ([#"{"amount":1}"#, #"{"amount":1}"#], ["Example 1", "Example 2"]),
  ])
  func newPayment(_ examples: [String], _ names: [String]) throws {
    let spec = try Spec.load(Fixtures.url("payments/spec.yaml"))
    let root = try spec.root("createPayment")
    #expect(ExampleNames.names(for: examples.map(json), of: root.node) == names)
  }

  @Test func fixtureExamples() throws {
    let spec = try Spec.load(Fixtures.url("payments/spec.yaml"))
    let payment = try spec.root("createPayment")
    #expect(
      ExampleNames.names(for: payment.examples, of: payment.node) == [
        "without reference", "with reference",
      ])
    // The spec's own names are kept.
    let refund = try spec.root("createRefund")
    #expect(
      ExampleNames.names(for: refund.examples, of: refund.node) == [
        "requested", "Rejected, with a reason",
      ])
    #expect(
      ExampleNames.names(for: refund.examples.map(\.value), of: refund.node) == [
        "status: Requested", "status: Rejected",
      ])
  }

  @Test func longValuesAreCutShort() throws {
    let (validator, root) = try Fixtures.inline(#"{"type":"object"}"#)
    _ = validator
    let long = String(repeating: "a", count: 40)
    #expect(
      ExampleNames.names(for: [json(#"{"a":"\#(long)"}"#), json(#"{"a":"b"}"#)], of: root.node)
        == ["a: \(String(repeating: "a", count: 29))…", "a: b"])
  }
}
