import SwiftUI
import AmbitickCore
import AmbitickMac

/// Top-right switcher shared by the Timeline and Pie windows: swap to the other
/// view (open it, dismiss this one) and remember the choice so the combined
/// entry point's "last viewed" mode is right.
struct TimeViewSwitcher: View {
    @ObservedObject var controller: AppController
    let current: TimeView
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(spacing: 2) {
            seg(.timeline, "rectangle.split.3x1", "Timeline")
            seg(.spent, "chart.pie", "Pie chart")
        }
    }

    private func seg(_ which: TimeView, _ icon: String, _ help: String) -> some View {
        Button {
            guard which != current else { return }
            controller.noteTimeViewOpened(which)
            openWindow(id: which == .timeline ? "timeline" : "spent")
            dismissWindow(id: current == .timeline ? "timeline" : "spent")
        } label: {
            Image(systemName: icon)
                .font(.callout)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(which == current ? Color.accentColor.opacity(0.25) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(which == current ? "\(help) (current)" : "Switch to \(help)")
    }
}

/// A compact donut of a project breakdown — the timeline window's "today"
/// cross-preview. Project-level only (no rings / hover), so it stays cheap.
struct MiniPie: View {
    let nodes: [TimeAggregator.Node]
    let colour: (TaskRef) -> Color

    var body: some View {
        let total = nodes.reduce(0) { $0 + $1.seconds }
        Canvas { ctx, size in
            guard total > 0 else { return }
            let side = min(size.width, size.height)
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = side * 0.5
            let hole = side * 0.28
            var a0 = -90.0
            for (i, n) in nodes.enumerated() {
                let sweep = 360 * n.seconds / total
                var p = Path()
                p.move(to: centre)
                p.addArc(center: centre, radius: r, startAngle: .degrees(a0),
                         endAngle: .degrees(a0 + sweep), clockwise: false)
                p.closeSubpath()
                ctx.fill(p, with: .color(wedgeColour(n, i)))
                a0 += sweep
            }
            var h = Path()
            h.addArc(center: centre, radius: hole, startAngle: .degrees(0),
                     endAngle: .degrees(360), clockwise: false)
            ctx.fill(h, with: .color(Color(nsColor: .windowBackgroundColor)))
        }
    }

    private func wedgeColour(_ n: TimeAggregator.Node, _ i: Int) -> Color {
        if let ref = n.ref ?? n.children.first?.ref { return colour(ref) }
        return Color(hue: (Double(i) * 0.13).truncatingRemainder(dividingBy: 1),
                     saturation: 0.5, brightness: 0.8)
    }
}

/// A compact, non-interactive timeline strip of slices over a range — the pie
/// window's "current block" cross-preview.
struct MiniTimeline: View {
    let sessions: [Session]
    let start: Date
    let end: Date
    let colour: (TaskRef) -> Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = max(end.timeIntervalSince(start), 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.06))
                ForEach(sessions) { s in
                    let x0 = CGFloat(s.start.timeIntervalSince(start) / span) * w
                    let x1 = CGFloat(s.end.timeIntervalSince(start) / span) * w
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colour(s.task).opacity(0.9))
                        .frame(width: max(x1 - x0, 2), height: 16)
                        .position(x: (x0 + x1) / 2, y: 11)
                }
            }
        }
        .frame(height: 22)
    }
}
