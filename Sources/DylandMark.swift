import SwiftUI

// Only schedule idle frames during the blink, not throughout the 4.8-second pause.
struct MascotSchedule: TimelineSchedule {
    var moving: Bool
    var paused: Bool

    func nextTick(after time: TimeInterval) -> TimeInterval {
        if moving { return time + 1.0 / 20 }
        let phase = time.truncatingRemainder(dividingBy: 4.8)
        if phase < 4.36 { return max(time + 1.0 / 30, time + 4.36 - phase) }
        if phase < 4.64 { return time + 1.0 / 30 }
        return time + 4.8 + 4.36 - phase
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        if paused { return AnySequence([startDate]) }
        return AnySequence(sequence(first: startDate) { date in
            Date(timeIntervalSinceReferenceDate: nextTick(after: date.timeIntervalSinceReferenceDate))
        })
    }
}

enum MascotStyle: String, CaseIterable {
    case capsule, ghost, hoodie

    var label: String {
        switch self {
        case .capsule: "Capsule"
        case .ghost: "Lilac Ghost"
        case .hoodie: "Hoodie"
        }
    }
    var color: Color {
        self == .capsule
            ? Color(red: 236 / 255, green: 236 / 255, blue: 231 / 255)
            : Color(red: 229 / 255, green: 224 / 255, blue: 239 / 255)
    }
    var baseColor: Color {
        self == .capsule
            ? Color(red: 69 / 255, green: 75 / 255, blue: 80 / 255)
            : Color(red: 101 / 255, green: 89 / 255, blue: 118 / 255)
    }
}

// Native, transparent variants of the A1 capsule and B1 ghost concepts.
struct DylandMark: View {
    var kind: String?
    var attentive = false
    var animating = true
    var style: MascotStyle = .capsule
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func eyes(at time: TimeInterval, reducedMotion: Bool) -> (height: CGFloat, x: CGFloat, y: CGFloat) {
        guard !reducedMotion, kind != "paused" else { return (eyeHeight, 0, 0) }
        let phase = time.truncatingRemainder(dividingBy: 4.8)
        let blink = max(0, 1 - abs(phase - 4.5) / 0.14)
        let height = attentive ? max(eyeHeight, 32) : eyeHeight
        let glance = kind == "working" && !attentive ? CGFloat(sin(time * .pi / 3)) * 3 : 0
        return (height + (2 - height) * blink, glance, attentive ? -3 : 0)
    }

    var eyeHeight: CGFloat {
        switch kind {
        case "done", "interrupted", "paused": 5
        case "question", "permission", "error": 32
        default: 30
        }
    }

    static let hoodieImages: [NSImage] = ["Hoodie-Cutout", "Hoodie-Blink"].compactMap { name in
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    private func drawHoodie(in context: inout GraphicsContext, eyes: (height: CGFloat, x: CGFloat, y: CGFloat)) {
        guard Self.hoodieImages.count == 2 else { return }
        let originalEyes = eyes.height >= 30
        context.draw(Image(nsImage: Self.hoodieImages[originalEyes ? 0 : 1]),
                     in: CGRect(x: 0, y: 0, width: 1000, height: 1140))
        guard !originalEyes else { return }
        for center in [CGPoint(x: 259, y: 592), CGPoint(x: 555, y: 708)] {
            var eyeContext = context
            eyeContext.translateBy(x: center.x, y: center.y)
            eyeContext.rotate(by: .degrees(22))
            let height = min(160, eyes.height / 30 * 160)
            let eye = RoundedRectangle(cornerRadius: min(32, height / 2))
                .path(in: CGRect(x: -32, y: -height / 2, width: 64, height: height))
            eyeContext.fill(eye, with: .color(Color(red: 0.10, green: 0.10, blue: 0.10)))
        }
    }

    var body: some View {
        TimelineView(MascotSchedule(moving: kind == "working" && !attentive, paused: !animating || reduceMotion || kind == "paused")) {
            timeline in
            let eyes = eyes(at: timeline.date.timeIntervalSinceReferenceDate, reducedMotion: reduceMotion || !animating)
            Canvas { context, size in
                if style == .hoodie {
                    context.scaleBy(x: size.width / 1000, y: size.height / 1140)
                    drawHoodie(in: &context, eyes: eyes)
                    return
                }
                context.scaleBy(x: size.width / 116, y: size.height / 77)
                context.translateBy(x: -8, y: -51)
                var body = Path()
                body.move(to: CGPoint(x: 8, y: 89))
                body.addCurve(
                    to: CGPoint(x: 49, y: 51), control1: CGPoint(x: 8, y: 65), control2: CGPoint(x: 25, y: 51)
                )
                body.addLine(to: CGPoint(x: 91, y: 51))
                body.addCurve(
                    to: CGPoint(x: 124, y: 90), control1: CGPoint(x: 112, y: 51),
                    control2: CGPoint(x: 124, y: 67))
                body.addLine(to: CGPoint(x: 124, y: 128))
                body.addLine(to: CGPoint(x: 8, y: 128))
                body.closeSubpath()
                if style == .ghost {
                    body = Path { path in
                        path.move(to: CGPoint(x: 16, y: 128))
                        path.addLine(to: CGPoint(x: 16, y: 90))
                        path.addCurve(to: CGPoint(x: 60, y: 51), control1: CGPoint(x: 16, y: 65), control2: CGPoint(x: 33, y: 51))
                        path.addCurve(to: CGPoint(x: 106, y: 91), control1: CGPoint(x: 87, y: 51), control2: CGPoint(x: 106, y: 67))
                        path.addCurve(to: CGPoint(x: 120, y: 117), control1: CGPoint(x: 106, y: 108), control2: CGPoint(x: 116, y: 106))
                        path.addCurve(to: CGPoint(x: 111, y: 128), control1: CGPoint(x: 122, y: 123), control2: CGPoint(x: 118, y: 128))
                        path.closeSubpath()
                    }
                }
                context.fill(body, with: .color(style.color))
                var base = Path()
                base.move(to: CGPoint(x: 8, y: 108))
                base.addCurve(
                    to: CGPoint(x: 124, y: 104), control1: CGPoint(x: 36, y: 115),
                    control2: CGPoint(x: 85, y: 116))
                base.addLine(to: CGPoint(x: 124, y: 128))
                base.addLine(to: CGPoint(x: 8, y: 128))
                base.closeSubpath()
                if style == .ghost {
                    base = Path { path in
                        path.move(to: CGPoint(x: 16, y: 113))
                        path.addCurve(to: CGPoint(x: 52, y: 114), control1: CGPoint(x: 30, y: 105), control2: CGPoint(x: 37, y: 120))
                        path.addCurve(to: CGPoint(x: 89, y: 113), control1: CGPoint(x: 67, y: 108), control2: CGPoint(x: 76, y: 120))
                        path.addCurve(to: CGPoint(x: 120, y: 118), control1: CGPoint(x: 102, y: 106), control2: CGPoint(x: 111, y: 119))
                        path.addLine(to: CGPoint(x: 124, y: 128))
                        path.addLine(to: CGPoint(x: 16, y: 128))
                        path.closeSubpath()
                    }
                }
                context.clip(to: body)
                context.fill(base, with: .color(style.baseColor))
                for x: CGFloat in [41.5, 75.5] {
                    let eye = RoundedRectangle(cornerRadius: min(6, eyes.height / 2))
                        .path(
                            in: CGRect(
                                x: x + eyes.x, y: 80.5 + eyes.y - eyes.height / 2, width: 12, height: eyes.height))
                    context.fill(eye, with: .color(Color(red: 20 / 255, green: 23 / 255, blue: 26 / 255)))
                }
            }
        }
        .aspectRatio(style == .hoodie ? 1000.0 / 1140.0 : 116.0 / 77.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
