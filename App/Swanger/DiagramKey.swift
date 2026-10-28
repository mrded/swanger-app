import SwangerCore
import SwiftUI

/// The mark at the start of a row and of the connector leaving it: what the field's presence is,
/// or that the row is a variant of a decision. Shapes differ as well as colours, so they read
/// without colour.
enum DiagramMark: CaseIterable {
  case required
  /// A rule requires or forbids the field.
  case conditional
  case optional
  case forbidden
  /// One variant of a choice applies.
  case decision

  init?(_ row: CardRow) {
    switch row.kind {
    case .field(let field): self.init(field.presence)
    case .variant: self = .decision
    case .heading, .other: return nil
    }
  }

  init(_ presence: Presence) {
    switch presence {
    case .required: self = .required
    case .conditional: self = .conditional
    case .optional: self = .optional
    case .forbidden: self = .forbidden
    }
  }

  var color: Color {
    switch self {
    case .required: .swangerTeal
    case .conditional, .decision: .swangerAmber
    case .optional, .forbidden: .secondary
    }
  }

  var meaning: String {
    switch self {
    case .required: "Required field"
    case .conditional: "Conditional: depends on a rule"
    case .optional: "Optional field"
    case .forbidden: "Not allowed in this request"
    case .decision: "A decision: one variant applies"
    }
  }

  /// Draws the mark centred on `point`, `size` across.
  func draw(in context: GraphicsContext, at point: CGPoint, size: CGFloat, color: Color) {
    let box = CGRect(
      x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    let ring = Path(ellipseIn: box.insetBy(dx: 0.5, dy: 0.5))
    switch self {
    case .required:
      context.fill(Path(ellipseIn: box), with: .color(color))
    case .conditional:
      var lower = Path()
      lower.addArc(
        center: point, radius: size / 2, startAngle: .zero, endAngle: .degrees(180),
        clockwise: false)
      lower.closeSubpath()
      context.fill(lower, with: .color(color))
      context.stroke(ring, with: .color(color), lineWidth: 1)
    case .optional:
      context.stroke(ring, with: .color(color), lineWidth: 1)
    case .forbidden:
      var slash = Path()
      let inset = size * 0.15
      slash.move(to: CGPoint(x: box.minX + inset, y: box.maxY - inset))
      slash.addLine(to: CGPoint(x: box.maxX - inset, y: box.minY + inset))
      context.stroke(ring, with: .color(color), lineWidth: 1)
      context.stroke(slash, with: .color(color), lineWidth: 1)
    case .decision:
      var diamond = Path()
      diamond.move(to: CGPoint(x: point.x, y: box.minY))
      diamond.addLine(to: CGPoint(x: box.maxX, y: point.y))
      diamond.addLine(to: CGPoint(x: point.x, y: box.maxY))
      diamond.addLine(to: CGPoint(x: box.minX, y: point.y))
      diamond.closeSubpath()
      context.fill(diamond, with: .color(color))
    }
  }
}

/// A ``DiagramMark`` as a view, for rows and the key.
struct DiagramMarkView: View {
  let mark: DiagramMark
  var size: CGFloat = 7

  var body: some View {
    Canvas { context, canvas in
      mark.draw(
        in: context, at: CGPoint(x: canvas.width / 2, y: canvas.height / 2), size: size,
        color: mark.color)
    }
    .frame(width: size + 2, height: size + 2)
    .accessibilityLabel(mark.meaning)
  }
}

/// How a connector is drawn, from the row it leaves: its line says whether the part it leads to
/// must, may or, by a rule, must be there, or is one variant of a decision.
enum LinkStyle: CaseIterable {
  case required
  case optional
  case conditional
  case decision

  init(_ row: CardRow) {
    switch DiagramMark(row) {
    case .required: self = .required
    case .conditional: self = .conditional
    case .decision: self = .decision
    // Pattern fields, other fields and array items needn't be there either.
    case .optional, .forbidden, nil: self = .optional
    }
  }

  var mark: DiagramMark {
    switch self {
    case .required: .required
    case .conditional: .conditional
    case .optional: .optional
    case .decision: .decision
    }
  }

  var meaning: String {
    switch self {
    case .required: "Leads to a required part"
    case .conditional: "Leads to a conditional part"
    case .optional: "Leads to an optional part"
    case .decision: "A decision: one variant applies"
    }
  }

  var stroke: StrokeStyle {
    switch self {
    case .required, .decision: StrokeStyle(lineWidth: 1.5)
    case .conditional: StrokeStyle(lineWidth: 1.5, dash: [6, 3])
    // Zero-length dashes with round caps are dots.
    case .optional: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0, 4])
    }
  }

  /// Draws `path` in this style and `color`, with its mark at `mark` in the mark's own colour, as
  /// the row it leaves shows it.
  func draw(_ path: Path, markAt mark: CGPoint, in context: GraphicsContext, color: Color) {
    context.stroke(path, with: .color(color), style: stroke)
    // Clears the line under the mark, so it doesn't show through a hollow one.
    var clear = context
    clear.blendMode = .clear
    clear.fill(
      Path(ellipseIn: CGRect(x: mark.x - 4.5, y: mark.y - 4.5, width: 9, height: 9)),
      with: .color(.black))
    self.mark.draw(in: context, at: mark, size: 7, color: self.mark.color)
  }
}

/// The key to the diagram's marks and lines, which folds away to a button.
struct DiagramKey: View {
  @AppStorage("diagramKeyShown") private var isShown = true

  var body: some View {
    Group {
      if isShown {
        VStack(alignment: .leading, spacing: 5) {
          HStack {
            Text("Key").font(.caption.weight(.semibold))
            Spacer()
            Button {
              isShown = false
            } label: {
              Image(systemName: "xmark")
            }
            .help("Hide the key")
          }
          ForEach([DiagramMark.required, .conditional, .optional, .forbidden], id: \.self) {
            mark in
            Label {
              Text(mark.meaning)
            } icon: {
              DiagramMarkView(mark: mark).frame(width: 28)
            }
          }
          Divider()
          ForEach(LinkStyle.allCases, id: \.self) { style in
            Label {
              Text(style.meaning)
            } icon: {
              LinkSample(style: style, color: style == .decision ? .swangerAmber : .secondary)
            }
          }
          Label {
            Text("Leads to a shared fragment")
          } icon: {
            LinkSample(style: .required, color: .swangerViolet)
          }
        }
        .font(.caption)
        .labelStyle(KeyLabelStyle())
        .padding(10)
        .frame(width: 250)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      } else {
        Button {
          isShown = true
        } label: {
          Label("Key", systemImage: "list.bullet.rectangle")
        }
        .help("Show the key to the diagram")
        .padding(6)
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: Capsule())
      }
    }
    .buttonStyle(.borderless)
    .padding(12)
  }
}

/// A short connector in a style, as the key shows it.
private struct LinkSample: View {
  let style: LinkStyle
  let color: Color

  var body: some View {
    Canvas { context, size in
      let start = CGPoint(x: 4, y: size.height / 2)
      var path = Path()
      path.move(to: start)
      path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
      style.draw(path, markAt: start, in: context, color: color)
    }
    .frame(width: 28, height: 10)
    .accessibilityHidden(true)
  }
}

/// The icon and title of a key entry, centred on each other.
private struct KeyLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 8) {
      configuration.icon
      configuration.title
    }
  }
}
