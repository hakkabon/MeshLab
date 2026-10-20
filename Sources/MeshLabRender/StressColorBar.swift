import Foundation
import simd

#if canImport(SwiftUI)
import SwiftUI

public enum StressPalette {
    public static let components: [SIMD3<Float>] = [
        SIMD3<Float>(0.09, 0.30, 0.75),
        SIMD3<Float>(0.10, 0.75, 0.85),
        SIMD3<Float>(0.25, 0.80, 0.30),
        SIMD3<Float>(0.98, 0.82, 0.15),
        SIMD3<Float>(0.90, 0.16, 0.12),
    ]

    public static func component(at value: Float) -> SIMD3<Float> {
        let t = min(max(value, 0), 1)
        guard let first = components.first, let last = components.last else {
            return .zero
        }
        if t <= 0 { return first }
        if t >= 1 { return last }
        let scaled = t * Float(components.count - 1)
        let lower = min(Int(scaled), components.count - 2)
        let fraction = scaled - Float(lower)
        return simd_mix(components[lower], components[lower + 1], SIMD3<Float>(repeating: fraction))
    }

    public static func color(at value: Float) -> Color {
        let component = component(at: value)
        return Color(
            red: Double(component.x),
            green: Double(component.y),
            blue: Double(component.z)
        )
    }
}

/// A compact stress legend matching the Metal heatmap palette.
public struct StressColorBar: View {
    public let range: ClosedRange<Float>
    public let title: String
    public let valueScale: Float
    public let unit: String

    public init(
        range: ClosedRange<Float>,
        title: String = "von Mises",
        valueScale: Float = 1,
        unit: String = ""
    ) {
        self.range = range
        self.title = title
        self.valueScale = valueScale
        self.unit = unit
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(format(range.upperBound * valueScale))
                .font(.caption2.monospacedDigit())
            LinearGradient(
                colors: StressPalette.components.reversed().map {
                    Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z))
                },
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 12, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(format(range.lowerBound * valueScale))
                .font(.caption2.monospacedDigit())
            Text(unit.isEmpty ? title : "\(title) (\(unit))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func format(_ value: Float) -> String {
        String(format: "%.4g", value)
    }
}
#endif
