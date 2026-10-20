import Foundation
import Testing

/// Compares `text` with `Snapshots/<name>.txt`.
///
/// A missing snapshot is written and the test fails, so it's looked at before it's trusted. Run
/// with `SNAPSHOT_RECORD=1` to rewrite snapshots after an intended change, and check the diff.
func expectSnapshot(
  _ text: String,
  named name: String,
  filePath: String = #filePath,
  sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
  let url = snapshotsFolder(from: filePath).appending(path: "\(name).txt")
  let recording = ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] != nil
  let existing = try? String(contentsOf: url, encoding: .utf8)

  if recording || existing == nil {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      Issue.record("Couldn't write \(url.path): \(error)", sourceLocation: sourceLocation)
      return
    }
    if existing == nil {
      Issue.record(
        "Recorded a new snapshot at \(url.path). Check it, then run the tests again.",
        sourceLocation: sourceLocation)
    }
    return
  }

  guard let existing, existing != text else { return }
  let expected = existing.split(separator: "\n", omittingEmptySubsequences: false)
  let actual = text.split(separator: "\n", omittingEmptySubsequences: false)
  let line =
    zip(expected, actual).enumerated().first { $0.element.0 != $0.element.1 }?.offset
    ?? min(expected.count, actual.count)
  let wanted = line < expected.count ? String(expected[line]) : "(end of snapshot)"
  let got = line < actual.count ? String(actual[line]) : "(end of output)"
  Issue.record(
    """
    \(name).txt differs from line \(line + 1):
      expected: \(wanted)
      actual:   \(got)
    Run with SNAPSHOT_RECORD=1 to update it if the change is intended.
    """,
    sourceLocation: sourceLocation)
}

/// `Tests/SwangerCoreTests/Snapshots`, found from the test file's own path.
private func snapshotsFolder(from filePath: String) -> URL {
  var folder = URL(filePath: filePath).deletingLastPathComponent()
  while folder.lastPathComponent != "SwangerCoreTests", folder.pathComponents.count > 1 {
    folder.deleteLastPathComponent()
  }
  return folder.appending(path: "Snapshots")
}
