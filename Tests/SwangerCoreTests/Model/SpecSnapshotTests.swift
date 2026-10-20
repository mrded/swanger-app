import Testing

@testable import SwangerCore

@Suite struct SpecSnapshotTests {
  @Test func outlineOfTheShopSpec() throws {
    let spec = try Spec.load(Fixtures.url("model/spec.yaml"))

    expectSnapshot(outline(spec), named: "shop-outline")
  }

  @Test func fragmentIndexOfTheShopSpec() throws {
    let spec = try Spec.load(Fixtures.url("model/spec.yaml"))

    expectSnapshot(fragmentIndexOutline(spec), named: "shop-fragment-index")
  }
}
