import SwiftUI

/// Draws the equaliser's real magnitude response and lets it be dragged.
///
/// The curve is the actual cascade response, not a spline through the band
/// points, so what is drawn is what is heard — including the way neighbouring
/// bands sum where they overlap.
struct CurveEditorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Band being dragged, used to show its readout.
    @State private var activeBand: Int?

    private let minDB: Double = -12
    private let maxDB: Double = 12
    private let lowFrequency: Double = 24
    private let highFrequency: Double = 22_000

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    draw(in: &context, size: canvasSize)
                }
                if let activeBand {
                    readout(for: activeBand, in: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: size))
            .onTapGesture(count: 2) { location in
                let index = bandIndex(forX: location.x, width: size.width)
                state.setBandGain(index, dB: 0)
            }
        }
        .frame(height: 220)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .accessibilityElement()
        .accessibilityLabel("이퀄라이저 곡선")
        .accessibilityValue(curveDescription)
        .accessibilityHint("자세히 조절하려면 20밴드 편집을 사용하세요")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.live)
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        drawGrid(in: &context, size: size)

        var path = Path()
        let steps = 160
        for step in 0...steps {
            let ratio = Double(step) / Double(steps)
            let frequency = lowFrequency * pow(highFrequency / lowFrequency, ratio)
            let dB = response(at: frequency)
            let point = CGPoint(x: ratio * size.width, y: y(forDB: dB, height: size.height))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }

        // Fill between the curve and the 0 dB line so cuts and boosts read at a
        // glance without relying on colour alone.
        var fill = path
        fill.addLine(to: CGPoint(x: size.width, y: y(forDB: 0, height: size.height)))
        fill.addLine(to: CGPoint(x: 0, y: y(forDB: 0, height: size.height)))
        fill.closeSubpath()
        context.fill(fill, with: .color(.accentColor.opacity(0.16)))
        context.stroke(path, with: .color(.accentColor), lineWidth: 2)

        for index in 0..<EQBands.count {
            let center = CGPoint(x: x(forFrequency: EQBands.frequencies[index], width: size.width),
                                 y: y(forDB: state.live.bandGainsDB[index], height: size.height))
            let radius: CGFloat = activeBand == index ? 6 : 4
            let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                             width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color(.accentColor))
            if activeBand == index {
                context.stroke(dot, with: .color(.white), lineWidth: 2)
            }
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        for dB in stride(from: minDB, through: maxDB, by: 6) {
            let position = y(forDB: dB, height: size.height)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: position))
            line.addLine(to: CGPoint(x: size.width, y: position))
            context.stroke(line,
                           with: .color(.secondary.opacity(dB == 0 ? 0.45 : 0.15)),
                           lineWidth: dB == 0 ? 1 : 0.5)
        }
        for frequency in [100.0, 1_000.0, 10_000.0] {
            let position = x(forFrequency: frequency, width: size.width)
            var line = Path()
            line.move(to: CGPoint(x: position, y: 0))
            line.addLine(to: CGPoint(x: position, y: size.height))
            context.stroke(line, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
        }
    }

    private func readout(for index: Int, in size: CGSize) -> some View {
        let gain = state.live.bandGainsDB[index]
        return Text("\(EQBands.label(index))  \(String(format: "%+.1f", gain)) dB")
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .position(x: min(max(x(forFrequency: EQBands.frequencies[index], width: size.width), 54),
                             size.width - 54),
                      y: 18)
            .allowsHitTesting(false)
    }

    // MARK: - Interaction

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeBand == nil { state.beginGesture() }
                // Painting: the band under the cursor follows the drag, which
                // is how people expect to sweep a curve.
                let index = bandIndex(forX: value.location.x, width: size.width)
                activeBand = index
                state.setBandGain(index, dB: dB(forY: value.location.y, height: size.height),
                                  isGesture: true)
            }
            .onEnded { _ in activeBand = nil }
    }

    private func bandIndex(forX position: CGFloat, width: CGFloat) -> Int {
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for index in 0..<EQBands.count {
            let distance = abs(x(forFrequency: EQBands.frequencies[index], width: width) - position)
            if distance < bestDistance { bestDistance = distance; best = index }
        }
        return best
    }

    // MARK: - Geometry

    private func response(at frequency: Double) -> Double {
        let rate = state.status.sampleRate > 0 ? state.status.sampleRate : 48_000
        var total = 0.0
        for index in 0..<EQBands.count {
            let gain = state.live.bandGainsDB[index]
            guard abs(gain) > 1e-6 else { continue }
            let coefficients = BiquadCoefficients(peakingAt: EQBands.frequencies[index],
                                                  sampleRate: rate,
                                                  q: EQBands.q,
                                                  gainDB: gain)
            total += coefficients.magnitudeDB(at: min(frequency, rate / 2 * 0.98), sampleRate: rate)
        }
        return total
    }

    private func x(forFrequency frequency: Double, width: CGFloat) -> CGFloat {
        let ratio = log(frequency / lowFrequency) / log(highFrequency / lowFrequency)
        return CGFloat(ratio) * width
    }

    private func y(forDB dB: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(dB, minDB), maxDB)
        let ratio = (maxDB - clamped) / (maxDB - minDB)
        return CGFloat(ratio) * height
    }

    private func dB(forY position: CGFloat, height: CGFloat) -> Double {
        let ratio = Double(min(max(position, 0), height) / max(height, 1))
        return maxDB - ratio * (maxDB - minDB)
    }

    private var curveDescription: String {
        let loud = state.live.bandGainsDB.enumerated()
            .filter { abs($0.element) >= 1 }
            .map { "\(EQBands.spokenLabel($0.offset)), \(EQBands.spokenGain($0.element))" }
        return loud.isEmpty ? "모든 밴드 0데시벨" : loud.joined(separator: ", ")
    }
}
