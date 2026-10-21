import SwangerCore
import SwiftUI

/// Sizes shared by the cards and the layout, so connectors meet the rows they come from.
enum DiagramMetrics {
  static let cardWidth: CGFloat = 270
  static let headerHeight: CGFloat = 46
  static let rowHeight: CGFloat = 24
  static let columnGap: CGFloat = 72
  static let cardGap: CGFloat = 18

  /// How far down a card the middle of row `index` is.
  static func rowMiddle(_ index: Int) -> CGFloat {
    headerHeight + rowHeight * (CGFloat(index) + 0.5)
  }
}

/// Where a card goes: its column, and the card and row it's opened from.
struct CardSlot: LayoutValueKey {
  static let defaultValue: (depth: Int, parent: (card: Int, row: Int)?) = (0, nil)
}

/// Places cards left to right, a column for each level. Each card lines up with the row it's
/// opened from, moved down when the cards above it in its column are in the way.
///
/// Subviews come parents first, as ``DiagramCards/cards(of:title:from:open:)`` gives them.
struct DiagramLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let frames = frames(of: subviews)
    return CGSize(
      width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for (subview, frame) in zip(subviews, frames(of: subviews)) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }

  private func frames(of subviews: Subviews) -> [CGRect] {
    var frames: [CGRect] = []
    var columnBottoms: [Int: CGFloat] = [:]
    for subview in subviews {
      let slot = subview[CardSlot.self]
      let size = subview.sizeThatFits(
        ProposedViewSize(width: DiagramMetrics.cardWidth, height: nil))
      var y: CGFloat = 0
      if let parent = slot.parent, frames.indices.contains(parent.card) {
        y =
          frames[parent.card].minY + DiagramMetrics.rowMiddle(parent.row)
          - DiagramMetrics.headerHeight / 2
      }
      if let bottom = columnBottoms[slot.depth] { y = max(y, bottom + DiagramMetrics.cardGap) }
      let x = CGFloat(slot.depth) * (DiagramMetrics.cardWidth + DiagramMetrics.columnGap)
      let frame = CGRect(x: x, y: max(y, 0), width: DiagramMetrics.cardWidth, height: size.height)
      frames.append(frame)
      columnBottoms[slot.depth] = frame.maxY
    }
    return frames
  }
}

/// Each card's bounds, by its path, for drawing connectors.
struct CardBounds: PreferenceKey {
  static let defaultValue: [FieldPath: Anchor<CGRect>] = [:]

  static func reduce(
    value: inout [FieldPath: Anchor<CGRect>], nextValue: () -> [FieldPath: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { $1 }
  }
}
