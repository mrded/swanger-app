import Foundation
import Testing

@testable import SwangerCore

@Suite struct LargeStackTests {
  private struct Failure: Error, Equatable {}

  @Test func returnsWhatTheWorkReturns() async {
    let value = await LargeStack.run { 42 }

    #expect(value == 42)
  }

  @Test func throwsWhatTheWorkThrows() async {
    await #expect(throws: Failure()) {
      try await LargeStack.run { () throws(Failure) -> Int in throw Failure() }
    }
  }

  @Test func recursesDeeperThanATaskCould() async {
    // Run directly in the test, this overflows a concurrency thread's 512 KB stack.
    let depth = await LargeStack.run { depth(of: 40_000) }

    #expect(depth == 40_000)
  }
}

/// Recurses `remaining` times and counts the frames.
@inline(never)
private func depth(of remaining: Int) -> Int {
  remaining > 0 ? depth(of: remaining - 1) + 1 : 0
}
