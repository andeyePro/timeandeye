import SwiftUI
import timeandeyeCore

// The phone timeline's DRAWING, factored out of TimelinePhoneView so it can
// be rendered headless with injected sample slices (visual verification on
// the build Mac via ImageRenderer) — keep this file free of UIKit and of
// PhoneController so it compiles on macOS unchanged. It mirrors the Mac
// TimelineView's look: horizontal time axis with adaptive ticks + labels,
// coloured slice bars with task labels, gaps as gaps, a red "now" line, and
// the live slice growing at the right with the Mac's zig-zag (torn) edge.

/// One drawn bar: a banked session or the live slice, pre-resolved to a
/// label + colour so the canvas needs no controller.
struct TimelineSlice: Identifiable, Equatable {
    let id: UUID
    let label: String
    let start: Date
    let end: Date
    let colour: Color
    let isLive: Bool
}

struct TimelineCanvas: View {
    let slices: [TimelineSlice]
    let viewStart: Date
    let viewSpan: TimeInterval
    let now: Date
    let selectedID: UUID?

    // Vertical layout: tick labels above the grid, the slice band centred,
    // grid lines running the full band height (the Mac bar scaled for touch).
    static let labelBand: CGFloat = 16
    static let sliceTop: CGFloat = 26
    static let sliceHeight: CGFloat = 84
    static let height: CGFloat = 122

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(height: Self.height)
    }

    private func xFor(_ date: Date, width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(viewStart) / viewSpan) * width
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let gridRect = CGRect(x: 0, y: Self.labelBand, width: size.width,
                              height: size.height - Self.labelBand)
        context.fill(Path(roundedRect: gridRect, cornerRadius: 8),
                     with: .color(.primary.opacity(0.06)))
        drawGrid(in: &context, size: size)
        for slice in slices where slice.end > viewStart
            && slice.start < viewStart.addingTimeInterval(viewSpan) {
            drawSlice(slice, in: &context, size: size)
        }
        drawNowLine(in: &context, size: size)
    }

    // MARK: Grid (hour ticks + labels, step adapting to zoom and width)

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let step = TimelineMath.tickStep(span: viewSpan, width: size.width)
        // Anchor ticks to local midnight so they land on round wall-clock
        // times (the viewport is clamped to one day, so one anchor is enough).
        let anchor = Calendar.current.startOfDay(for: viewStart)
        let firstK = (viewStart.timeIntervalSince(anchor) / step).rounded(.down)
        var tick = anchor.addingTimeInterval(firstK * step)
        let end = viewStart.addingTimeInterval(viewSpan + step)
        while tick <= end {
            let x = xFor(tick, width: size.width)
            if x > -1, x < size.width + 1 {
                var line = Path()
                line.move(to: CGPoint(x: x, y: Self.labelBand))
                line.addLine(to: CGPoint(x: x, y: Self.height))
                context.stroke(line, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                // A label centred on an edge tick would half-clip — skip it
                // (the line still marks the hour).
                if x > 20, x < size.width - 20 {
                    context.draw(
                        Text(tick.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary),
                        at: CGPoint(x: x, y: Self.labelBand / 2))
                }
            }
            tick = tick.addingTimeInterval(step)
        }
    }

    // MARK: Slices

    private func drawSlice(_ slice: TimelineSlice, in context: inout GraphicsContext,
                           size: CGSize) {
        let x0 = xFor(slice.start, width: size.width)
        let x1 = xFor(slice.end, width: size.width)
        let w = max(x1 - x0, 3)
        let rect = CGRect(x: x0, y: Self.sliceTop, width: w, height: Self.sliceHeight)
        let path = Self.slicePath(in: rect, zigzag: slice.isLive)
        context.fill(path, with: .color(slice.colour.opacity(0.9)))
        if slice.id == selectedID {
            context.stroke(path, with: .color(.accentColor), lineWidth: 2.5)
        }
        if w > 44 {
            // Task label inside the bar, clipped to it (wraps in the tall
            // touch bar where the Mac's single 9 pt line would clip).
            let inset = rect.insetBy(dx: 4, dy: 5)
            var layer = context
            layer.clip(to: Path(inset))
            layer.draw(
                Text(slice.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(readableText(on: slice.colour, in: context)),
                in: inset)
        }
    }

    /// The Mac's slice shape: rounded rect, but the live slice gets a zig-zag
    /// (torn) right edge meaning "ongoing" — same geometry as timeandeyeUI's
    /// SliceShape, as a plain Path so the phone Canvas can use it.
    static func slicePath(in rect: CGRect, zigzag: Bool) -> Path {
        let r: CGFloat = 3
        guard zigzag else { return Path(roundedRect: rect, cornerRadius: r) }
        var p = Path()
        let tooth: CGFloat = 5
        let xR = rect.maxX - tooth
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: xR, y: rect.minY))
        let steps = 5
        let dy = rect.height / CGFloat(steps)
        for i in 0..<steps {
            let y = rect.minY + dy * CGFloat(i)
            p.addLine(to: CGPoint(x: rect.maxX, y: y + dy / 2))
            p.addLine(to: CGPoint(x: xR, y: y + dy))
        }
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }

    /// Black on light fills, white on dark — the Mac's readableTextColour,
    /// via SwiftUI's resolved colour so it needs no AppKit/UIKit.
    private func readableText(on colour: Color, in context: GraphicsContext) -> Color {
        let c = colour.resolve(in: context.environment)
        let luminance = 0.299 * Double(c.red) + 0.587 * Double(c.green)
            + 0.114 * Double(c.blue)
        return luminance > 0.55 ? .black : .white
    }

    // MARK: Now line

    private func drawNowLine(in context: inout GraphicsContext, size: CGSize) {
        guard now >= viewStart,
              now <= viewStart.addingTimeInterval(viewSpan) else { return }
        let x = xFor(now, width: size.width)
        var line = Path()
        line.move(to: CGPoint(x: x, y: Self.labelBand + 2))
        line.addLine(to: CGPoint(x: x, y: Self.height))
        context.stroke(line, with: .color(.red.opacity(0.8)), lineWidth: 1.5)
        let knob = CGRect(x: x - 3, y: Self.labelBand - 1, width: 6, height: 6)
        context.fill(Path(ellipseIn: knob), with: .color(.red))
    }
}
