import SwiftUI

/// One continuous equalizer surface. The 10-band view is a presentation of
/// the same 20-band DSP state, so switching modes never changes the sound.
struct CurveEditorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var activeBand: Int?

    private let minDB: Double = -12
    private let maxDB: Double = 12
    private let lowFrequency: Double = 24
    private let highFrequency: Double = 22_000

    private var visibleBandIndices: [Int] {
        state.showTwentyBands
            ? Array(0..<EQBands.count)
            : Array(stride(from: 0, to: EQBands.count, by: 2))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let plotRect = plotRect(in: size)
            let faderHeight = plotRect.height + 40
            let hitWidth = max(44, min(64, plotRect.width / CGFloat(visibleBandIndices.count) * 0.94))

            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    draw(in: &context, size: canvasSize, plotRect: plotRect)
                }

                axisLabels(in: plotRect)

                ForEach(visibleBandIndices, id: \.self) { index in
                    EQFader(
                        index: index,
                        value: state.live.bandGainsDB[index],
                        railHeight: plotRect.height,
                        isActive: activeBand == index,
                        isEQEnabled: state.eqEnabled,
                        tint: tint(for: index),
                        onBegin: {
                            activeBand = index
                            state.beginGesture()
                        },
                        onChange: { gain in
                            state.setBandGain(index, dB: gain, isGesture: true)
                        },
                        onEnd: {
                            activeBand = nil
                        }
                    )
                    .frame(width: hitWidth, height: faderHeight)
                    .position(x: x(forFrequency: EQBands.frequencies[index], in: plotRect),
                              y: plotRect.minY + plotRect.height / 2 + 20)
                }
            }
            .contentShape(Rectangle())
        }
        .frame(minHeight: 320, maxHeight: .infinity)
        .background(.background)
        .overlay(alignment: .top) { Divider().opacity(0.55) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("curve.a11y.label"))
        .accessibilityHint(L("curve.a11y.hint"))
        // Presets glide into place; the active fader is always immediate.
        .animation((reduceMotion || activeBand != nil) ? nil : .easeOut(duration: 0.15),
                   value: state.live)
    }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: 36,
               y: 16,
               width: max(size.width - 48, 1),
               height: max(size.height - 64, 1))
    }

    @ViewBuilder
    private func axisLabels(in rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach([-12.0, -6.0, 0.0, 6.0, 12.0], id: \.self) { dB in
                Text(String(format: "%+.0f", dB))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(dB == 0 ? .primary : .secondary)
                    .position(x: 16, y: y(forDB: dB, height: rect.height))
            }
        }
        .frame(width: 32, height: rect.height)
        .position(x: 16, y: rect.midY)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, plotRect: CGRect) {
        drawGrid(in: &context, plotRect: plotRect)
        drawSpectrum(in: &context, plotRect: plotRect)

        var path = Path()
        let steps = 180
        for step in 0...steps {
            let ratio = Double(step) / Double(steps)
            let frequency = lowFrequency * pow(highFrequency / lowFrequency, ratio)
            let point = CGPoint(
                x: x(forFrequency: frequency, in: plotRect),
                y: plotRect.minY + y(forDB: response(at: frequency), height: plotRect.height)
            )
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        context.stroke(path,
                       with: .color(Color.macEQAccent.opacity(state.eqEnabled ? 0.58 : 0.22)),
                       lineWidth: 1.25)
    }

    private func drawSpectrum(in context: inout GraphicsContext, plotRect: CGRect) {
        guard state.spectrumEnabled, state.status.spectrumDB.count == EQBands.count else { return }

        var path = Path()
        for index in 0..<EQBands.count {
            let db = Double(state.status.spectrumDB[index])
            let level = min(max((db + 80) / 80, 0), 1)
            let point = CGPoint(
                x: x(forFrequency: EQBands.frequencies[index], in: plotRect),
                y: plotRect.maxY - CGFloat(level) * plotRect.height * 0.55
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        // Measured spectrum stays quieter than the EQ response and has no fill
        // or glow, so it remains a peripheral cue rather than the focal point.
        context.stroke(path, with: .color(Color.secondary.opacity(0.28)), lineWidth: 1)
    }

    private func drawGrid(in context: inout GraphicsContext, plotRect: CGRect) {
        for dB in stride(from: minDB, through: maxDB, by: 6) {
            let y = plotRect.minY + y(forDB: dB, height: plotRect.height)
            var line = Path()
            line.move(to: CGPoint(x: plotRect.minX, y: y))
            line.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            context.stroke(line,
                           with: .color(dB == 0 ? Color.primary.opacity(0.34) : Color.secondary.opacity(0.13)),
                           lineWidth: dB == 0 ? 1 : 0.5)
        }

        for frequency in [100.0, 1_000.0, 10_000.0] {
            let x = x(forFrequency: frequency, in: plotRect)
            var line = Path()
            line.move(to: CGPoint(x: x, y: plotRect.minY))
            line.addLine(to: CGPoint(x: x, y: plotRect.maxY))
            context.stroke(line, with: .color(Color.secondary.opacity(0.11)), lineWidth: 0.5)
        }
    }

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

    private func x(forFrequency frequency: Double, in rect: CGRect) -> CGFloat {
        let ratio = log(frequency / lowFrequency) / log(highFrequency / lowFrequency)
        return rect.minX + CGFloat(ratio) * rect.width
    }

    private func y(forDB dB: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(dB, minDB), maxDB)
        return CGFloat((maxDB - clamped) / (maxDB - minDB)) * height
    }

    private func tint(for index: Int) -> Color {
        switch index {
        case 0..<(EQBands.count / 3): return .macEQLow
        case (EQBands.count * 2 / 3)..<EQBands.count: return .macEQHigh
        default: return .primary
        }
    }
}

/// Direct-manipulation fader with a deliberately quiet physical cue: one rail
/// and one small horizontal thumb, no knob, card, bevel, or shadow.
struct EQFader: View {
    let index: Int
    let value: Double
    let railHeight: CGFloat
    let isActive: Bool
    let isEQEnabled: Bool
    let tint: Color
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Rectangle()
                    .fill(Color.secondary.opacity(isEQEnabled ? 0.28 : 0.14))
                    .frame(width: 2)

                if isActive {
                    Rectangle()
                        .fill(tint.opacity(0.72))
                        .frame(width: 2)
                }

                RoundedRectangle(cornerRadius: 1)
                    .fill((isActive || isHovered) ? tint : Color.primary.opacity(0.72))
                    .frame(width: 20, height: 4)
                    .offset(y: thumbOffset)
            }
            .frame(height: railHeight)

            Text(EQBands.shortLabel(index))
                .font(.caption2.monospacedDigit())
                .foregroundStyle((isActive || isHovered) ? tint : .secondary)
                .lineLimit(1)
                .frame(height: 16)
        }
        .opacity(isEQEnabled ? 1 : 0.62)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if !isDragging {
                        isDragging = true
                        onBegin()
                    }
                    onChange(gain(forY: gesture.location.y))
                }
                .onEnded { _ in
                    isDragging = false
                    onEnd()
                }
        )
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EQBands.spokenLabel(index))
        .accessibilityValue(EQBands.spokenGain(value))
        .accessibilityHint(L("curve.a11y.dragHint"))
        .accessibilityAdjustableAction { direction in
            onBegin()
            switch direction {
            case .increment:
                onChange(EQBands.clamp(value + 0.5))
            case .decrement:
                onChange(EQBands.clamp(value - 0.5))
            @unknown default:
                break
            }
            onEnd()
        }
    }

    private var thumbOffset: CGFloat {
        let ratio = (EQBands.maxGainDB - value) / (EQBands.maxGainDB - EQBands.minGainDB)
        return CGFloat(ratio) * railHeight - railHeight / 2
    }

    private func gain(forY position: CGFloat) -> Double {
        let clamped = min(max(position, 0), max(railHeight, 1))
        let ratio = Double(clamped / max(railHeight, 1))
        return EQBands.maxGainDB - ratio * (EQBands.maxGainDB - EQBands.minGainDB)
    }
}
