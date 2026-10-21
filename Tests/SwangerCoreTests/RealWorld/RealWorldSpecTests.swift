import Foundation
import SwangerValidation
import Testing

@testable import SwangerCore

/// Public specs load without warnings or crashes, and in reasonable time.
///
/// The Petstores are kept as fixtures (Apache 2.0, see `Fixtures/real-world/README.md`). GitHub's
/// is too big to keep, so `scripts/fetch-real-world-specs.sh` downloads it first
/// (`make real-world`). Without it that test is skipped, unless `REQUIRE_REAL_WORLD_SPECS` is set,
/// as CI does, when it fails.
@Suite struct RealWorldSpecTests {
  @Test func petstore30() async throws {
    let spec = try await loadCleanly(
      Fixtures.url("real-world/petstore-3.0.yaml"), within: .seconds(5))

    #expect(spec.warnings.isEmpty, "\(spec.warnings)")
    #expect(spec.requestSchemas.map(\.name).contains("Pet"))
    #expect(spec.responseSchemas.map(\.name).contains("Pet"))
    #expect(spec.fragments.map(\.name).contains("Category"))
  }

  @Test func petstore31() async throws {
    let spec = try await loadCleanly(
      Fixtures.url("real-world/petstore-3.1.json"), within: .seconds(5))

    // `$ref`s to a schema's `$id` and `$anchor` aren't followed yet
    // (docs/backlog/refs-to-id-and-anchor.md).
    #expect(
      Set(spec.warnings.map(\.kind.ref)).sorted() == [
        "/api/v31/components/schemas/petdetails",
        "/api/v31/components/schemas/petdetails#pet_details_id",
      ])
    #expect(spec.requestSchemas.map(\.name) == ["updatePet request", "addPet request"])
    #expect(spec.responseSchemas.map(\.name).contains("Pet"))
    #expect(spec.fragments.map(\.name).contains("Category"))
  }

  @Test(.enabled(if: GitHubSpec.available, "Run scripts/fetch-real-world-specs.sh first"))
  func gitHub() async throws {
    // Generous, because tests run unoptimised on a shared CI runner: this is to catch a slowdown
    // that makes the app unusable, not to measure it.
    let spec = try await loadCleanly(GitHubSpec.url, within: .seconds(120))

    #expect(spec.warnings.isEmpty, "\(spec.warnings.prefix(5))")
    #expect(spec.roots.count > 1000)
    #expect(spec.fragments.count > 500)
  }

  @Test(.enabled(if: !GitHubSpec.available && GitHubSpec.required))
  func gitHubSpecIsThereWhenRequired() {
    Issue.record("REQUIRE_REAL_WORLD_SPECS is set but \(GitHubSpec.url.path) is missing")
  }

  /// Loads the spec, then builds a skeleton for every root and checks it, which compiles every
  /// root's validator. On a ``LargeStack``, as the app does.
  private func loadCleanly(_ url: URL, within limit: Duration) async throws -> Spec {
    let clock = ContinuousClock()
    let start = clock.now
    let spec = try await LargeStack.run { () throws(LoadError) in try Spec.load(url) }
    let loaded = clock.now - start
    #expect(!spec.roots.isEmpty)

    await LargeStack.run {
      let validator = PayloadValidator(spec: spec)
      for root in spec.roots {
        _ = validator.issues(in: Skeleton.payload(for: root.node, in: spec), for: root)
      }
    }
    let total = clock.now - start

    #expect(total < limit, "Took \(total) (loading \(loaded)), more than \(limit)")
    return spec
  }
}

extension LoadWarning.Kind {
  fileprivate var ref: String {
    switch self {
    case .unresolvedReference(let ref, _): ref
    }
  }
}

private enum GitHubSpec {
  /// `github.json` in `REAL_WORLD_SPECS`, else in `.build/real-world-specs` at the repo root,
  /// where the script downloads it.
  static let url: URL = {
    let folder =
      ProcessInfo.processInfo.environment["REAL_WORLD_SPECS"].map {
        URL(filePath: $0, directoryHint: .isDirectory, relativeTo: repoRoot)
      } ?? repoRoot.appending(path: ".build/real-world-specs")
    return folder.appending(path: "github.json")
  }()

  static let available = FileManager.default.fileExists(atPath: url.path)

  static let required = ProcessInfo.processInfo.environment["REQUIRE_REAL_WORLD_SPECS"] != nil

  private static let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
}
