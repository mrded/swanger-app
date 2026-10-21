import Foundation
import OrderedJSON
import SwangerCore
import Testing

@testable import SwangerValidation

@Suite struct PayloadValidatorTests {
  @Test(arguments: Fixtures.specs)
  func everyExampleIsValidAsWritten(_ url: URL) throws {
    let spec = try Spec.load(url)
    let validator = PayloadValidator(spec: spec)
    var checked = 0
    for root in spec.roots {
      for example in root.examples {
        #expect(validator.issues(in: example.value, for: root) == [], "\(root.name): \(example)")
        checked += 1
      }
    }
    for fragment in spec.fragments {
      for example in fragment.node.examples {
        #expect(validator.issues(in: example, for: fragment) == [], "\(fragment.name)")
        checked += 1
      }
    }
    print("\(url.lastPathComponent): \(checked) examples")
  }

  /// swift-json-schema 0.14 lets `additionalProperties` see the `properties` of a `$ref` beside
  /// it, so `{$ref: X, additionalProperties: false}` accepts X's fields. JSON Schema says they're
  /// other fields there, as ajv agrees; the compiled document moves the `$ref` into `allOf` so
  /// they are.
  @Test func additionalPropertiesBesideARefDoesntSeeItsFields() throws {
    let (validator, root) = try Fixtures.inline(
      ##"{"$ref":"#/components/schemas/X","additionalProperties":false}"##,
      components: #"{"X":{"properties":{"a":{}}}}"#)
    #expect(
      validator.issues(in: json(#"{"a":1}"#), for: root).map(\.description) == [
        "/a: Unexpected field: `a` isn't allowed"
      ])
    let (items, tuple) = try Fixtures.inline(
      ##"{"$ref":"#/components/schemas/X","items":false}"##,
      components: #"{"X":{"prefixItems":[{}]}}"#)
    #expect(
      items.issues(in: json("[1]"), for: tuple).map(\.description) == [
        "/0: Unexpected field: There are more items than allowed"
      ])
  }

  @Test func unevaluatedPropertiesBesideARefClosesIt() throws {
    let validator = try Fixtures.validator("payments/spec.yaml")
    let root = try validator.spec.root("createPayment")
    let payload = json(
      #"{"amount":1,"currency":"GBP","method":{"type":"card","number":"4111111111111111"},"billing":{"line1":"1 High St","postcode":"AB1","line3":"x"}}"#
    )
    #expect(
      validator.issues(in: payload, for: root).map(\.description) == [
        "/billing/line3: Unexpected field: `line3` isn't allowed"
      ])
  }

  @Test func unevaluatedPropertiesSeesTheFieldsOfARefBesideIt() throws {
    let validator = try Fixtures.validator("payments/spec.yaml")
    let root = try validator.spec.root("createPayment", status: "201")
    let valid = json(#"{"id":"6f1c2a54-58b1-4a0e-9d7e-0b8f4e1f2c3d","amount":5}"#)
    #expect(validator.issues(in: valid, for: root) == [])
    let extra = json(#"{"id":"6f1c2a54-58b1-4a0e-9d7e-0b8f4e1f2c3d","tip":5}"#)
    #expect(
      validator.issues(in: extra, for: root).map(\.description) == [
        "/tip: Unexpected field: `tip` isn't allowed"
      ])
  }

  @Test func readsOpenAPI30AsNormalised() throws {
    let validator = try Fixtures.validator("legacy.yaml")
    let root = try validator.spec.root("createNote")
    #expect(validator.issues(in: json(#"{"text":null}"#), for: root) == [])
    #expect(
      validator.issues(in: json(#"{"text":"a","priority":0,"due":"31/01/2024"}"#), for: root)
        .map(\.description) == [
          "/priority: Out of range: Must be more than 0",
          "/due: Wrong format: Must be a date, such as 2024-01-31",
        ])
  }

  @Test func followsRecursiveRefsIntoOtherFiles() throws {
    let validator = try Fixtures.validator("payments/spec.yaml")
    let root = try validator.spec.root("replaceTags")
    let payload = json(#"[{"name":"a","children":[{"name":"b","children":[{"name":""}]}]}]"#)
    #expect(
      validator.issues(in: payload, for: root).map(\.description) == [
        "/0/children/0/children/0/name: Out of range: Needs at least 1 character"
      ])
  }

  /// The model doesn't show `propertyNames`, but its `$ref`s are still followed.
  @Test func followsRefsTheModelDoesntShow() throws {
    let (validator, root) = try Fixtures.inline(
      ##"{"propertyNames":{"$ref":"#/components/schemas/Key"}}"##,
      components: #"{"Key":{"pattern":"^[a-z]+$"}}"#)
    #expect(validator.issues(in: json(#"{"ab":1}"#), for: root) == [])
    #expect(
      validator.issues(in: json(#"{"A":1}"#), for: root).map(\.description) == [
        "/: Rule not met: Field names must match `propertyNames`"
      ])
  }

  @Test func compilesEachSchemaOnce() throws {
    let validator = try Fixtures.validator("payments/spec.yaml")
    let root = try validator.spec.root("createRefund")
    for _ in 0..<3 { _ = validator.issues(in: json("{}"), for: root) }
    #expect(validator.isValid(json("{}"), forSchemaAt: root.id.location) == false)
    #expect(validator.compiledCount == 1)
  }

  @Test func aLocationThatIsntASchemaAllowsAnything() throws {
    let validator = try Fixtures.validator("payments/spec.yaml")
    let nowhere = NodeLocation(file: validator.spec.url, pointer: .root.appending("info"))
    #expect(validator.issues(in: json("1"), forSchemaAt: nowhere) == [])
  }
}
