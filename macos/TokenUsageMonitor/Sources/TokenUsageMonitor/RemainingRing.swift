import SwiftUI

struct RemainingRing: View {
    let remainingPercent: Double?
    let size: CGFloat
    let lineWidth: CGFloat
    let fontSize: CGFloat
    var showsValue = true

    private var normalized: Double {
        min(100, max(0, remainingPercent ?? 0))
    }

    private var displayValue: String {
        guard let remainingPercent else { return "--" }
        return "\(Int(min(100, max(0, remainingPercent)).rounded()))%"
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.18))
            if remainingPercent != nil {
                Circle()
                    .trim(from: 0, to: normalized / 100)
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: .black.opacity(0.3), radius: 1)
                    .animation(.easeInOut(duration: 0.3), value: normalized)
            }
            if showsValue {
                Text(displayValue)
                    .font(.system(size: fontSize, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("剩余额度")
        .accessibilityValue(displayValue)
    }
}
