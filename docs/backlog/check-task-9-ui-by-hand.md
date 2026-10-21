---
worth: yes
where: App/Swanger/DiagramView.swift
added: 2026-10-21
---
# Check task 9's hover, pinch and swipe by hand

The rest of task 9 was checked in the running app on 2026-10-21 by driving it with synthesised events.
Those can't show tooltips, pinch or make a three-finger swipe, so these are still unchecked:

- Overview: hovering a dot in the usage grid shows the paths (`.help`), and so does a rotated column
  header.
- Diagram: pinch zooms around the pinch point and stays in step with ⌘= ⌘- ⌘0.
- History: a three-finger swipe goes back and forward, restoring the page, the open cards and the
  viewport.

Build and open the Shop fixture:

```sh
xcodebuild -project App/Swanger.xcodeproj -scheme Swanger -derivedDataPath .build/xcode-dd build
open -a "$PWD/.build/xcode-dd/Build/Products/Debug/Swanger.app" Tests/SwangerCoreTests/Fixtures/model/spec.yaml
```
