---
worth: yes
where: App/Swanger/DiagramView.swift
added: 2026-10-21
---
# Check task 9's diagram, overview and history in the running app

Task 9 (overview, diagram, inspector, search, history) was built and reviewed without screen-recording
permission. Only the layout was checked, by rendering `SchemaPage` offscreen with `ImageRenderer` (light
and dark looked right; `ScrollView`, `Form` and buttons don't render that way, so the overview and the
inspector were never seen). None of the interactions were tried.

Build and open the Shop fixture:

```sh
xcodebuild -project App/Swanger.xcodeproj -scheme Swanger -derivedDataPath .build/xcode-dd build
open -a .build/xcode-dd/Build/Products/Debug/Swanger.app Tests/SwangerCoreTests/Fixtures/model/spec.yaml
```

Then check, with screenshots:

- Overview: request schema cards, the usage grid (rotated column headers, filled/outlined dots, hover
  paths, "Include responses"), and clicking a card or dot.
- Diagram: clicking rows opens and closes cards; connectors meet their rows at every zoom; dragging on a
  card pans instead of swallowing the click; pinch, ⌘-scroll and plain scroll; ⌘= ⌘- ⌘0; double-clicking a
  header opens a fragment page or shows the card on its own, and "Show the whole schema" comes back.
- Inspector (toggle it on, since it starts hidden): field details, rules, "Each item" for `array of
  string`, "Defined in" and "Used in" links.
- Search: ⌘F focuses the sidebar field; `address`, `lines[].sku` and `customer`; choosing a field opens,
  selects and scrolls to it.
- History: ⌘[ ⌘], the toolbar arrows and a three-finger swipe restore the page, the open cards and the
  viewport; Back does nothing (and doesn't reset the zoom) when there's nowhere to go.
- Dark mode, and a large spec for speed (opening many cards; search on every keystroke).

Known going in: opening the window with the inspector already showing made AppKit throw "more Update
Constraints in Window passes than there are views" on macOS 27, so it starts hidden. Worth checking
whether toggling it on later is fine.
