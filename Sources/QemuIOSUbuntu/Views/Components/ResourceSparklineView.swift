import SwiftUI

/// Gráfico leve em linha + preenchimento suave para exibir histórico recente de CPU/RAM da VM.
public struct ResourceSparklineView: View {
    public let title: String
    public let currentValueText: String
    public let values: [Double]
    public let maxValue: Double
    public let tint: Color

    public init(
        title: String,
        currentValueText: String,
        values: [Double],
        maxValue: Double,
        tint: Color
    ) {
        self.title = title
        self.currentValueText = currentValueText
        self.values = values
        self.maxValue = max(1, maxValue)
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(currentValueText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
            }

            GeometryReader { geo in
                let points = normalizedPoints(in: geo.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tint.opacity(0.08))

                    if points.count >= 2 {
                        Path { path in
                            path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                            for pt in points {
                                path.addLine(to: pt)
                            }
                            path.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                            path.closeSubpath()
                        }
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.32), tint.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        Path { path in
                            path.move(to: points[0])
                            for pt in points.dropFirst() {
                                path.addLine(to: pt)
                            }
                        }
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    } else {
                        Text("Aguardando telemetria...")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(height: 46)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let stepX = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, val in
            let clamped = min(max(0, val / maxValue), 1.0)
            let x = CGFloat(index) * stepX
            let y = size.height - (CGFloat(clamped) * (size.height - 6)) - 3
            return CGPoint(x: x, y: y)
        }
    }
}

