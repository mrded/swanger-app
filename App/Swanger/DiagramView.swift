import AppKit
import SwangerCore
import SwiftUI

/// The cards of a schema, joined by connectors, on a surface that pans and zooms.
///
/// Drag or scroll to pan; pinch or ⌘-scroll to zoom.
struct DiagramView: View {
  let cards: [DiagramCard]
  let state: DiagramState
  /// Saved viewport to start from, or `nil` for the initial one.
  let savedViewport: Viewport?
  /// Changes when the window goes back or forward, to put back ``savedViewport``.
  let restoreCount: Int
  /// A row found by searching, to scroll into view once its card is laid out.
  let reveal: FieldPath?
  let didReveal: () -> Void
  let viewportChanged: (Viewport) -> Void
  let selectRow: (CardRow) -> Void
  let openOnItsOwn: (DiagramCard) -> Void
  let clearSelection: () -> Void

  @State private var viewport = Viewport.initial
  @State private var viewSize = CGSize.zero
  @State private var contentSize = CGSize.zero
  @State private var cardFrames: [FieldPath: CGRect] = [:]
  @State private var dragStart: CGSize?
  @State private var pinchStart: Viewport?
  @State private var pointer: CGPoint?
  @State private var scrollMonitor: Any?
  @State private var host = HostWindow()

  private static let scales: ClosedRange<CGFloat> = 0.2...3

  var body: some View {
    Color.clear
      .contentShape(Rectangle())
      .onTapGesture(perform: clearSelection)
      // An overlay, so the cards' size doesn't become the diagram's minimum size: that squeezed
      // the inspector, and resizing the window then made AppKit throw.
      .overlay(alignment: .topLeading) {
        content
          .fixedSize()
          .onGeometryChange(for: CGSize.self, of: \.size) { contentSize = $0 }
          .scaleEffect(viewport.scale, anchor: .topLeading)
          .offset(viewport.offset)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .clipped()
      .background(DiagramBackground())
      .onGeometryChange(for: CGSize.self, of: \.size) { viewSize = $0 }
      .gesture(pan)
      .simultaneousGesture(pinch)
      .onContinuousHover { phase in
        if case .active(let location) = phase { pointer = location } else { pointer = nil }
      }
      .overlay(alignment: .bottomTrailing) { zoomControls }
      .background(HostWindow.Reader(host: host))
      .onAppear {
        viewport = savedViewport ?? .initial
        viewportChanged(viewport)
        installScrollMonitor()
      }
      .onDisappear(perform: removeScrollMonitor)
      .onChange(of: restoreCount) {
        viewport = savedViewport ?? .initial
      }
      .onChange(of: viewport) { _, viewport in viewportChanged(viewport) }
      .onChange(of: cardFrames) { revealRow() }
      .onChange(of: reveal) { revealRow() }
  }

  private var content: some View {
    DiagramLayout {
      ForEach(Array(cards.enumerated()), id: \.element.id) { _, card in
        CardView(
          card: card, openRows: state.openRows, selection: state.selection,
          highlight: state.highlight, selectRow: selectRow,
          openOnItsOwn: { openOnItsOwn(card) }
        )
        .layoutValue(key: CardSlot.self, value: (card.depth, card.parent))
      }
    }
    .padding(1)
    .backgroundPreferenceValue(CardBounds.self) { anchors in
      GeometryReader { proxy in
        let frames = anchors.mapValues { proxy[$0] }
        Connectors(cards: cards, frames: frames)
          .onAppear { cardFrames = frames }
          .onChange(of: frames) { _, frames in cardFrames = frames }
      }
    }
  }

  // MARK: - Panning and zooming

  private var pan: some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { value in
        let start = dragStart ?? viewport.offset
        dragStart = start
        viewport.offset = CGSize(
          width: start.width + value.translation.width,
          height: start.height + value.translation.height)
      }
      .onEnded { _ in dragStart = nil }
  }

  private var pinch: some Gesture {
    MagnifyGesture()
      .onChanged { value in
        let start = pinchStart ?? viewport
        pinchStart = start
        let anchor = CGPoint(
          x: value.startAnchor.x * viewSize.width, y: value.startAnchor.y * viewSize.height)
        viewport = zoomed(start, to: start.scale * value.magnification, around: anchor)
      }
      .onEnded { _ in pinchStart = nil }
  }

  /// `viewport` at `scale`, keeping the point under `anchor` where it is.
  private func zoomed(_ viewport: Viewport, to scale: CGFloat, around anchor: CGPoint) -> Viewport {
    let scale = min(max(scale, Self.scales.lowerBound), Self.scales.upperBound)
    let ratio = scale / viewport.scale
    return Viewport(
      scale: scale,
      offset: CGSize(
        width: anchor.x - (anchor.x - viewport.offset.width) * ratio,
        height: anchor.y - (anchor.y - viewport.offset.height) * ratio))
  }

  private func zoom(by factor: CGFloat) {
    let middle = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    withAnimation(.snappy) {
      viewport = zoomed(viewport, to: viewport.scale * factor, around: middle)
    }
  }

  private func zoomToFit() {
    guard contentSize.width > 0, contentSize.height > 0 else { return }
    let margin: CGFloat = 24
    let scale = min(
      (viewSize.width - margin * 2) / contentSize.width,
      (viewSize.height - margin * 2) / contentSize.height, 1)
    let clamped = max(scale, Self.scales.lowerBound)
    withAnimation(.snappy) {
      viewport = Viewport(
        scale: clamped,
        offset: CGSize(
          width: max((viewSize.width - contentSize.width * clamped) / 2, margin),
          height: max((viewSize.height - contentSize.height * clamped) / 2, margin)))
    }
  }

  /// Scrolls so the row to reveal is in the middle.
  private func revealRow() {
    guard let reveal,
      let card = cards.first(where: { $0.rows.contains { $0.path == reveal } }),
      let frame = cardFrames[card.id]
    else { return }
    didReveal()
    let row = card.rows.firstIndex { $0.path == reveal } ?? 0
    let target = CGPoint(x: frame.midX, y: frame.minY + DiagramMetrics.rowMiddle(row))
    withAnimation(.snappy) {
      viewport.offset = CGSize(
        width: viewSize.width / 2 - target.x * viewport.scale,
        height: viewSize.height / 2 - target.y * viewport.scale)
    }
  }

  private var zoomControls: some View {
    HStack(spacing: 0) {
      Button {
        zoom(by: 1 / 1.25)
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .keyboardShortcut("-")
      .help("Zoom out")
      Button {
        zoom(by: 1.25)
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .keyboardShortcut("=")
      .help("Zoom in")
      Button(action: zoomToFit) {
        Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
      }
      .keyboardShortcut("0")
      .help("Zoom to fit")
    }
    .buttonStyle(.borderless)
    .padding(6)
    .background(.regularMaterial, in: Capsule())
    .padding(12)
  }

  /// Scrolling pans, and ⌘-scrolling zooms around the pointer, while the pointer is over the
  /// diagram.
  private func installScrollMonitor() {
    guard scrollMonitor == nil else { return }
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
      let isUsed = MainActor.assumeIsolated { handleScroll(event) }
      return isUsed ? nil : event
    }
  }

  private func removeScrollMonitor() {
    if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    scrollMonitor = nil
  }

  /// Whether the scroll was used.
  private func handleScroll(_ event: NSEvent) -> Bool {
    // The monitor sees every window's scrolling, and the hover can outlast a window opened on top.
    guard let pointer, event.window === host.window else { return false }
    let deltaX = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 8
    let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
    if event.modifierFlags.contains(.command) {
      viewport = zoomed(viewport, to: viewport.scale * (1 + deltaY / 200), around: pointer)
    } else {
      viewport.offset.width += deltaX
      viewport.offset.height += deltaY
    }
    return true
  }
}

/// The window a view is in, held weakly so the view doesn't keep it alive.
@MainActor private final class HostWindow {
  weak var window: NSWindow?

  struct Reader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> ReaderView {
      let view = ReaderView()
      view.host = host
      return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
      view.host = host
      host.window = view.window
    }
  }

  final class ReaderView: NSView {
    var host: HostWindow?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      host?.window = window
    }
  }
}

/// The lines from each open row to the card it opens.
private struct Connectors: View {
  let cards: [DiagramCard]
  let frames: [FieldPath: CGRect]

  var body: some View {
    Canvas { context, _ in
      for card in cards {
        guard let parent = card.parent, let child = frames[card.id],
          let from = frames[cards[parent.card].id]
        else { continue }
        let start = CGPoint(x: from.maxX, y: from.minY + DiagramMetrics.rowMiddle(parent.row))
        let end = CGPoint(x: child.minX, y: child.minY + DiagramMetrics.headerHeight / 2)
        let bend = (end.x - start.x) / 2
        var path = Path()
        path.move(to: start)
        path.addCurve(
          to: end, control1: CGPoint(x: start.x + bend, y: start.y),
          control2: CGPoint(x: end.x - bend, y: end.y))
        let color = color(for: card, from: cards[parent.card].rows[parent.row])
        context.stroke(path, with: .color(color), lineWidth: 1.5)
        context.fill(
          Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)),
          with: .color(color))
      }
    }
  }

  private func color(for card: DiagramCard, from row: CardRow) -> Color {
    if case .variant = row.kind { return .swangerAmber }
    return card.node.fragment != nil ? .swangerViolet : .secondary
  }
}

/// A faint dot grid behind the cards.
private struct DiagramBackground: View {
  var body: some View {
    Canvas { context, size in
      let spacing: CGFloat = 20
      for x in stride(from: spacing / 2, to: size.width, by: spacing) {
        for y in stride(from: spacing / 2, to: size.height, by: spacing) {
          context.fill(
            Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)),
            with: .color(.secondary.opacity(0.25)))
        }
      }
    }
    .background(Color(nsColor: .underPageBackgroundColor))
  }
}
