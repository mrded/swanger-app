import Foundation
import Testing

@testable import SwangerCore

@Suite final class FileWatcherTests {
  /// A fresh folder with `spec.yaml` and `common.yaml` in it.
  private let folder: URL
  private var spec: URL { folder.appending(path: "spec.yaml") }
  private var common: URL { folder.appending(path: "common.yaml") }

  init() throws {
    folder = FileManager.default.temporaryDirectory
      .appending(path: "FileWatcherTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "openapi: 3.1.0\n".write(to: spec, atomically: false, encoding: .utf8)
    try "Pet: {}\n".write(to: common, atomically: false, encoding: .utf8)
  }

  deinit {
    try? FileManager.default.removeItem(at: folder)
  }

  @Test func writingAFileCallsBack() async throws {
    let changes = Changes()
    let watcher = FileWatcher(urls: [spec, common], latency: .milliseconds(50)) {
      changes.record()
    }
    defer { watcher.cancel() }

    try append("Owner: {}\n", to: common)

    #expect(await changes.wait(for: 1))
  }

  @Test func aBurstOfWritesCallsBackOnce() async throws {
    let changes = Changes()
    let watcher = FileWatcher(urls: [spec], latency: .milliseconds(200)) { changes.record() }
    defer { watcher.cancel() }

    for line in 0..<5 { try append("# \(line)\n", to: spec) }

    #expect(await changes.wait(for: 1))
    try await Task.sleep(for: .milliseconds(500))
    #expect(changes.count == 1)
  }

  @Test func keepsWatchingAFileReplacedByAnAtomicSave() async throws {
    let changes = Changes()
    let watcher = FileWatcher(urls: [spec], latency: .milliseconds(50)) { changes.record() }
    defer { watcher.cancel() }

    try "openapi: 3.0.3\n".write(to: spec, atomically: true, encoding: .utf8)
    #expect(await changes.wait(for: 1))

    // The replacement is a new file, so this is only seen if the watch moved over to it.
    try append("info: {}\n", to: spec)
    #expect(await changes.wait(for: 2))
  }

  @Test func noticesAMissingFileBeingCreated() async throws {
    let missing = folder.appending(path: "later.yaml")
    let changes = Changes()
    let watcher = FileWatcher(urls: [spec, missing], latency: .milliseconds(50)) {
      changes.record()
    }
    defer { watcher.cancel() }

    try "Later: {}\n".write(to: missing, atomically: false, encoding: .utf8)

    #expect(await changes.wait(for: 1))
  }

  @Test func noticesAFileCreatedInAMissingFolder() async throws {
    let schemas = folder.appending(path: "schemas/v1")
    let missing = schemas.appending(path: "Pet.yaml")
    let changes = Changes()
    let watcher = FileWatcher(urls: [spec, missing], latency: .milliseconds(50)) {
      changes.record()
    }
    defer { watcher.cancel() }

    // One folder at a time, letting the watcher move down to each before the next arrives.
    for path in ["schemas", "schemas/v1"] {
      try FileManager.default.createDirectory(
        at: folder.appending(path: path), withIntermediateDirectories: false)
      try await Task.sleep(for: .milliseconds(300))
    }
    try "Pet: {}\n".write(to: missing, atomically: false, encoding: .utf8)

    #expect(await changes.wait(for: 1))
  }

  @Test func canBeCancelledFromItsCallback() async throws {
    let changes = Changes()
    let box = WatcherBox()
    box.watcher = FileWatcher(urls: [spec], latency: .milliseconds(50)) {
      box.watcher?.cancel()
      changes.record()
    }

    try append("info: {}\n", to: spec)
    #expect(await changes.wait(for: 1))

    try append("servers: []\n", to: spec)
    try await Task.sleep(for: .milliseconds(400))
    #expect(changes.count == 1)
  }

  @Test func ignoresOtherFilesInTheFolder() async throws {
    let changes = Changes()
    let watcher = FileWatcher(urls: [spec], latency: .milliseconds(50)) { changes.record() }
    defer { watcher.cancel() }

    try "notes\n".write(to: folder.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

    try await Task.sleep(for: .milliseconds(400))
    #expect(changes.count == 0)
  }

  @Test func callsBackForAChangeMadeBeforeItStarted() async throws {
    // The file is read, then edited before the watcher exists, as when a load is still running.
    let readAt = Date()
    try await Task.sleep(for: .milliseconds(20))
    try append("info: {}\n", to: common)

    let changes = Changes()
    let watcher = FileWatcher(
      urls: [spec, common], changedSince: readAt, latency: .milliseconds(50)
    ) { changes.record() }
    defer { watcher.cancel() }

    #expect(await changes.wait(for: 1))
  }

  @Test func doesNotCallBackForFilesUnchangedSinceTheyWereRead() async throws {
    try await Task.sleep(for: .milliseconds(20))
    let changes = Changes()
    let watcher = FileWatcher(
      urls: [spec, common], changedSince: Date(), latency: .milliseconds(50)
    ) {
      changes.record()
    }
    defer { watcher.cancel() }

    try await Task.sleep(for: .milliseconds(400))
    #expect(changes.count == 0)
  }

  @Test func doesNotCallBackOnceCancelled() async throws {
    let changes = Changes()
    let watcher = FileWatcher(urls: [spec], latency: .milliseconds(50)) { changes.record() }
    watcher.cancel()

    try append("info: {}\n", to: spec)

    try await Task.sleep(for: .milliseconds(400))
    #expect(changes.count == 0)
  }

  private func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
  }
}

/// Counts callbacks from a watcher.
private final class Changes: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded = 0

  var count: Int { lock.withLock { recorded } }

  func record() { lock.withLock { recorded += 1 } }

  /// Waits up to five seconds for at least `expected` callbacks.
  func wait(for expected: Int) async -> Bool {
    for _ in 0..<100 {
      if count >= expected { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return count >= expected
  }
}

/// Lets a watcher's callback reach the watcher.
private final class WatcherBox: @unchecked Sendable {
  var watcher: FileWatcher?
}
