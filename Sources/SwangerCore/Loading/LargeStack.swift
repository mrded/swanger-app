import Foundation

/// Runs work that recurses as deep as a spec's schemas nest on a thread with a large stack.
///
/// Building the model and validating recurse once per level of nesting, and large real-world specs
/// (GitHub's) nest deep enough to overflow the 512 KB stack of a Swift concurrency thread, in
/// debug builds at least. Use this instead of `Task.detached` for loading, compiling and
/// validating.
public enum LargeStack {
  /// The stack size, 64 MB. Only the pages a thread touches are given memory.
  public static let size = 64 << 20

  /// Runs `work` on a new thread with a ``size`` stack and returns what it returns.
  public static func run<T: Sendable, E: Error>(
    qualityOfService: QualityOfService = .userInitiated,
    _ work: @escaping @Sendable () throws(E) -> T
  ) async throws(E) -> T {
    let result: Result<T, E> = await withCheckedContinuation { continuation in
      let thread = Thread {
        continuation.resume(returning: Result { () throws(E) -> T in try work() })
      }
      thread.stackSize = size
      thread.qualityOfService = qualityOfService
      thread.name = "Swanger large stack"
      thread.start()
    }
    return try result.get()
  }
}
