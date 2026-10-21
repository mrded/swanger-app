---
worth: later
where: Sources/SwangerCore/Loading/FileWatcher.swift:109
added: 2026-10-21
---
# A symlinked folder in a `$ref` path isn't watched for being repointed

`FileWatcher` watches each file, the file a symbolic link points to, and the folders they're in. A
symbolic link to a *folder* part-way along a path isn't covered: for `$ref: schemas/current/Pet.yaml`
where `current` → `versions/v1`, repointing `current` at `versions/v2` changes nothing the watcher sees
(opening `schemas/current` follows the link, so `schemas` itself isn't watched), and the window keeps
showing v1 until something else changes.

Fix: for each path, watch the folder holding every symbolic link met while resolving it, and work the
links out again on each re-arm. Found by a Codex review of task 8.

Unknown: whether anyone keeps specs behind repointed folder links (a "current version" link is the
likely case). Drop it if nobody does.
