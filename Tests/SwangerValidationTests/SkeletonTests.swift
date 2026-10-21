import OrderedJSON
import SwangerCore
import Testing

@testable import SwangerValidation

@Suite struct SkeletonTests {
  @Test(arguments: [
    // Required fields only; the first allowed value; a choice's first variant.
    ("createPayment", #"{"amount":0,"currency":"GBP","method":{"type":"card","number":""}}"#),
    ("createRefund", #"{"paymentId":"","status":"Requested"}"#),
    // One item, for items with fields to fill in.
    ("replaceTags", #"[{"name":""}]"#),
    // A required field that leads back to its own fragment ends.
    ("getChain", #"{"name":"","next":{}}"#),
  ])
  func payment(_ operation: String, _ expected: String) throws {
    let spec = try Spec.load(Fixtures.url("payments/spec.yaml"))
    let root = try spec.root(operation, status: operation == "getChain" ? "200" : nil)
    #expect(Skeleton.payload(for: root.node, in: spec) == json(expected))
  }

  @Test func openAPI30() throws {
    let spec = try Spec.load(Fixtures.url("legacy.yaml"))
    let root = try spec.root("createNote")
    #expect(Skeleton.payload(for: root.node, in: spec) == json(#"{"text":""}"#))
  }

  @Test func scalarsAndDefaults() throws {
    let (validator, root) = try Fixtures.inline(
      #"{"type":"object","required":["a","b","c","d","e","f"],"properties":{"a":{"type":"integer","default":3},"b":{"type":["null","boolean"]},"c":{"enum":[null,"x"]},"d":{"type":"array","items":{"type":"string"}},"e":{},"f":false}}"#
    )
    #expect(
      Skeleton.payload(for: root.node, in: validator.spec)
        == json(#"{"a":3,"b":false,"c":"x","d":[],"e":null}"#))
  }
}
