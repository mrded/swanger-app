---
worth: yes
where: Package.swift:44
added: 2026-10-20
---
# SwiftPM warns that the snapshot files are unhandled

Every build prints `found 2 file(s) which are unhandled; explicitly declare them as resources or exclude
from the target` for `Tests/SwangerCoreTests/Snapshots/*.txt`. They're read by path from the source tree
(`Support/Snapshot.swift`), so they should be listed under `exclude:` for the `SwangerCoreTests` target.
One line, but the warning hides new ones in the build output.
