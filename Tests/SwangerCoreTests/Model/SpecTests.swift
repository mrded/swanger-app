import Foundation
import OrderedJSON
import Testing

@testable import SwangerCore

/// The model of the Shop fixture: roots, fragments, choices, conditions and the fragment index.
@Suite struct SpecTests {
  private let spec: Spec

  init() throws {
    spec = try Spec.load(Fixtures.url("model/spec.yaml"))
  }

  // MARK: - Roots

  @Test func findsRequestAndResponseRoots() {
    #expect(spec.requestSchemas.map(\.name) == ["NewOrder", "updateOrderStatus request"])
    #expect(
      spec.responseSchemas.map(\.name) == [
        "Order", "createOrder 400 response", "listCategories 200 response",
      ])
    #expect(spec.title == "Shop")
    #expect(spec.apiVersion == "2.0.0")
    #expect(spec.warnings.isEmpty)
  }

  @Test func componentUsedBySeveralOperationsIsOneRoot() throws {
    let order = try root("Order", in: spec.responseSchemas)

    #expect(order.operations.map(\.description) == ["POST /orders 201", "GET /orders/{id} 200"])
  }

  @Test func prefersJSONMediaTypes() throws {
    let problem = try root("createOrder 400 response", in: spec.responseSchemas)
    let order = try root("Order", in: spec.responseSchemas)

    #expect(problem.operations.map(\.mediaType) == ["application/problem+json"])
    // GET /orders/{id} lists text/plain first.
    #expect(order.operations.map(\.mediaType) == ["application/json", "application/json"])
  }

  @Test func rootExamplesComeFromTheSchemaThenTheMediaType() throws {
    let newOrder = try root("NewOrder", in: spec.requestSchemas)

    #expect(newOrder.examples.map(\.source) == [.schema, .mediaType])
    #expect(newOrder.examples.map(\.name) == [nil, "Paid by card"])
  }

  @Test func rootStats() throws {
    let status = try root("updateOrderStatus request", in: spec.requestSchemas)
    let categories = try root("listCategories 200 response", in: spec.responseSchemas)

    #expect(status.stats == RootStats(fields: 2, fragments: 0, rules: 3))
    #expect(categories.stats == RootStats(fields: 2, fragments: 1, rules: 0))
  }

  // MARK: - Fragments

  @Test func componentThatPointsAtAFileIsOneFragment() throws {
    let address = try fragment("Address")

    #expect(address.id.file.lastPathComponent == "address.yaml")
    #expect(address.id.pointer == .root)
    #expect(
      address.node.object?.fields.map(\.name) == ["line1", "line2", "town", "postcode", "country"])
    #expect(spec.fragments.contains { $0.name == "address" } == false)
  }

  @Test func fragmentsAreSortedByUsage() {
    #expect(spec.fragments.first?.name == "NewOrder")
    #expect(spec.fragments.last?.name == "Category")
  }

  @Test func fieldsKnowTheFragmentTheyComeFrom() throws {
    let order = try #require(fragment("Order").node.object)

    #expect(order[field: "customer"]?.definedIn?.name == "NewOrder")
    #expect(order[field: "customer"]?.fragmentUsed?.name == "Customer")
    #expect(order[field: "id"]?.definedIn == nil)
    #expect(order[field: "id"]?.isRequired == true)
  }

  @Test func keywordsBesideARefTightenTheFragment() throws {
    let newOrder = try #require(fragment("NewOrder").node.object)
    let billing = try #require(newOrder[field: "billingAddress"]?.node)
    let delivery = try #require(newOrder[field: "deliveryAddress"]?.node)
    let address = try #require(fragment("Address").node.object)

    #expect(billing.fragment?.name == "Address")
    #expect(billing.isTightened)
    #expect(billing.object?[field: "line2"]?.isForbidden == true)
    #expect(billing.object?[field: "town"]?.isRequired == true)
    #expect(delivery.isTightened)
    #expect(delivery.object?[field: "postcode"]?.isRequired == true)
    #expect(delivery.description == "Where to deliver. Defaults to the customer's address.")
    // The fragment itself is unchanged.
    #expect(address[field: "postcode"]?.isRequired == false)
    #expect(address[field: "line2"]?.isForbidden == false)
  }

  @Test func discriminatedOneOf() throws {
    let payment = try #require(fragment("Payment").node.choice)

    #expect(payment.mode == .oneOf)
    #expect(payment.discriminator == "method")
    #expect(payment.variants.map(\.name) == ["Card", "BankTransfer"])
    #expect(payment.variants.map(\.discriminatorValue) == ["card", "bank-transfer"])
  }

  @Test func recursiveSchema() throws {
    let category = try #require(fragment("Category").node.object)
    let items = try #require(category[field: "subcategories"]?.node.array?.items)

    #expect(items.kind == .recursive(try fragment("Category").reference))
  }

  // MARK: - Rules

  @Test func conditionRule() throws {
    let status = try root("updateOrderStatus request", in: spec.requestSchemas)

    #expect(
      status.node.rules.map(\.text) == [
        #"When `status` is "Rejected": `reason` is required. Otherwise: `reason` isn't allowed"#
      ])
  }

  @Test func choiceRulesWithAndWithoutADiscriminator() throws {
    #expect(
      try fragment("Payment").node.rules.map(\.text) == [
        #"When `method` is "card": it's a `Card`"#,
        #"When `method` is "bank-transfer": it's a `BankTransfer`"#,
      ])
    #expect(try fragment("Payment").node.rules.map(\.fields) == [["method"], ["method"]])
    #expect(
      try fragment("Customer").node.rules.map(\.text) == ["Needs exactly one of `email` or `phone`"]
    )
  }

  @Test func dependencyRule() throws {
    #expect(
      try fragment("NewOrder").node.rules.map(\.text) == [
        "When `giftMessage` is present: `giftWrap` is required"
      ])
  }

  // MARK: - Fragment index

  @Test func directAndNestedUses() throws {
    let index = spec.fragmentIndex
    let newOrder = try root("NewOrder", in: spec.requestSchemas).id
    let order = try root("Order", in: spec.responseSchemas).id

    #expect(index.use(of: try fragment("Customer").reference, in: newOrder) == .direct)
    #expect(index.use(of: try fragment("Customer").reference, in: order) == .nested)
    #expect(index.use(of: try fragment("Money").reference, in: newOrder) == .nested)
    #expect(index.use(of: try fragment("Category").reference, in: newOrder) == nil)
    #expect(
      index.usages(of: try fragment("Money").reference).map(\.path.description) == [
        "lines[].unitPrice", "lines[].unitPrice",
      ])
  }

  @Test func fragmentsInUnlistedFieldsAreUsed() throws {
    let maps = try Spec.load(Fixtures.url("model/composed.yaml"))
    let prices = try root("setPrices request", in: maps.requestSchemas)
    let price = try #require(maps.fragments.first { $0.name == "Price" })
    let note = try #require(maps.fragments.first { $0.name == "Note" })

    #expect(maps.fragmentIndex.usages(of: price.reference).map(\.path.description) == ["*"])
    #expect(maps.fragmentIndex.usages(of: note.reference).map(\.path.description) == ["/^x-/"])
    // `currency` and Price's `amount`; Price's minimum and Note's length.
    #expect(prices.stats == RootStats(fields: 2, fragments: 2, rules: 2))
  }

  @Test func fragmentWithoutFieldsIsUsedByTheOneItTightens() throws {
    let composed = try Spec.load(Fixtures.url("model/composed.yaml"))
    let rename = try root("ShortName", in: composed.requestSchemas)
    let name = try #require(composed.fragments.first { $0.name == "Name" })

    #expect(composed.fragmentIndex.roots(using: name.reference).first == rename.id)
    #expect(rename.stats == RootStats(fields: 0, fragments: 1, rules: 1))
  }

  @Test func basesOfBasesAreUsed() throws {
    let composed = try Spec.load(Fixtures.url("model/composed.yaml"))
    let nickname = try root("TinyName", in: composed.requestSchemas)
    let name = try #require(composed.fragments.first { $0.name == "Name" })

    #expect(composed.fragmentIndex.roots(using: name.reference).contains(nickname.id))
    // ShortName and Name.
    #expect(nickname.stats == RootStats(fields: 0, fragments: 2, rules: 1))
  }

  @Test func filesWithTheSameNameAreDifferentRoots() throws {
    let composed = try Spec.load(Fixtures.url("model/composed.yaml"))
    let models = composed.requestSchemas.filter {
      $0.node.location.file.lastPathComponent == "model.yaml"
    }

    #expect(models.count == 2)
    #expect(models.map { $0.operations.map(\.path) } == [["/customers"], ["/orders"]])
    #expect(models.map { $0.node.object?.fields.map(\.name) ?? [] } == [["email"], ["total"]])
  }

  @Test func sharedRootKeepsEveryUsesExamples() throws {
    let composed = try Spec.load(Fixtures.url("model/composed.yaml"))
    let name = try root("Name", in: composed.requestSchemas)

    // In the order the operations are read: PUT, then POST.
    #expect(name.examples.map(\.value) == ["Grace", "Ada"])
  }

  @Test func unusedAliasesAreNotLoaded() throws {
    let composed = try Spec.load(Fixtures.url("model/composed.yaml"))

    #expect(composed.warnings.isEmpty)
    #expect(!composed.referencedFiles.contains { $0.lastPathComponent == "missing.yaml" })
  }

  @Test func variantsBesideCommonFieldsAreUsed() throws {
    let composed = try Spec.load(Fixtures.url("model/composed.yaml"))
    let pay = try root("pay request", in: composed.requestSchemas)
    let card = try #require(composed.fragments.first { $0.name == "Card" })

    #expect(composed.fragmentIndex.usages(of: card.reference).map(\.path.description) == ["(Card)"])
    // `id`, Card's `number` and Cash's `change`; the choice and Card's pattern.
    #expect(pay.stats == RootStats(fields: 3, fragments: 2, rules: 2))
  }

  // MARK: - Helpers

  private func root(_ name: String, in roots: [RootSchema]) throws -> RootSchema {
    try #require(roots.first { $0.name == name })
  }

  private func fragment(_ name: String) throws -> Fragment {
    try #require(spec.fragments.first { $0.name == name })
  }
}

extension FragmentIndex.Use: Equatable {}
