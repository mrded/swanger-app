import Testing

@testable import SwangerCore

/// Searching the Shop fixture, and finding nodes by path.
@Suite struct SearchIndexTests {
  private let spec: Spec
  private let index: SearchIndex

  init() throws {
    spec = try Spec.load(Fixtures.url("model/spec.yaml"))
    index = SearchIndex(spec: spec)
  }

  @Test func ranksExactThenPrefixThenWordStartThenContains() {
    #expect(SearchIndex.quality(of: "Address", for: "address") == .exact)
    #expect(SearchIndex.quality(of: "addressLine", for: "address") == .prefix)
    #expect(SearchIndex.quality(of: "deliveryAddress", for: "address") == .wordStart)
    #expect(SearchIndex.quality(of: "billing_address", for: "address") == .wordStart)
    #expect(SearchIndex.quality(of: "subaddress", for: "address") == .contains)
    #expect(SearchIndex.quality(of: "name", for: "address") == nil)
  }

  @Test func fragmentBeforeTheFieldsNamedLikeIt() {
    let results = index.search("address")

    #expect(results.first?.target == .fragment(fragment("Address")))
    #expect(results.dropFirst().first?.detail == "NewOrder · customer.address")
    // Exact names come before `deliveryAddress` and `billingAddress`.
    let names = results.map(\.name)
    #expect(names.firstIndex(of: "deliveryAddress")! > names.lastIndex(of: "address")!)
  }

  @Test func fieldMatchesOnItsOwnNameOnly() {
    let results = index.search("customer")

    #expect(results.allSatisfy { $0.name.localizedStandardContains("customer") })
  }

  @Test func dottedQueryMatchesTheEndOfAPath() {
    let results = index.search("lines[].sku")

    #expect(!results.isEmpty)
    #expect(results.allSatisfy { $0.detail?.hasSuffix("lines[].sku") == true })
  }

  @Test func findsNodesAndFieldsByPath() throws {
    let newOrder = try #require(spec.requestSchemas.first { $0.name == "NewOrder" }).node
    let sku = FieldPath([.field("lines"), .items, .field("sku")])
    let card = FieldPath([.field("payment"), .variant("Card", index: 0), .field("cardNumber")])

    #expect(newOrder.field(at: sku)?.isRequired == true)
    #expect(newOrder.node(at: card)?.scalar?.patterns == [#"^\d{16}$"#])
    #expect(newOrder.node(at: FieldPath([.field("nope")])) == nil)
  }

  private func fragment(_ name: String) -> FragmentRef {
    spec.fragments.first { $0.name == name }!.reference
  }
}
