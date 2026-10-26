import Foundation
import simd

public struct ElementQuality: Sendable, Hashable, Codable {
    public let elementIndex: Int
    public let measure: Double
    /// Scale-independent Jacobian indicator. Larger values are better; zero is
    /// degenerate. Values are comparable within an element family.
    public let quality: Double
    public let isInverted: Bool
}

public struct MeshQualityReport: Sendable, Hashable, Codable {
    public let elements: [ElementQuality]
    public let minimumQuality: Double
    public let meanQuality: Double
    public let maximumQuality: Double
    public let invertedElementIndices: [Int]

    public func elementIndices(below threshold: Double) -> [Int] {
        elements.filter { $0.quality < threshold }.map(\.elementIndex)
    }
}

public extension Mesh {
    func qualityReport() -> MeshQualityReport {
        let values = elements.indices.map { index -> ElementQuality in
            let coordinates = elementCoordinates(index)
            let element = elements[index]
            switch element.type {
            case .tetrahedron4:
                let first = coordinates[1] - coordinates[0]
                let second = coordinates[2] - coordinates[0]
                let third = coordinates[3] - coordinates[0]
                let signedDeterminant = simd_dot(first, simd_cross(second, third))
                let edges = [
                    first, second, third,
                    coordinates[2] - coordinates[1],
                    coordinates[3] - coordinates[1],
                    coordinates[3] - coordinates[2],
                ]
                let scale = edges.map(simd_length).max() ?? 0
                let quality = scale > 0
                    ? abs(signedDeterminant) / (scale * scale * scale)
                    : 0
                return ElementQuality(
                    elementIndex: index,
                    measure: abs(signedDeterminant) / 6,
                    quality: quality,
                    isInverted: signedDeterminant < 0
                )
            case .triangle3:
                let first = coordinates[1] - coordinates[0]
                let second = coordinates[2] - coordinates[0]
                let third = coordinates[2] - coordinates[1]
                let signedTwiceArea = first.x * second.y - first.y * second.x
                let scale = max(
                    hypot(first.x, first.y),
                    hypot(second.x, second.y),
                    hypot(third.x, third.y)
                )
                let quality = scale > 0 ? abs(signedTwiceArea) / (scale * scale) : 0
                return ElementQuality(
                    elementIndex: index,
                    measure: abs(signedTwiceArea) / 2,
                    quality: quality,
                    isInverted: signedTwiceArea < 0
                )
            }
        }
        let qualities = values.map(\.quality)
        return MeshQualityReport(
            elements: values,
            minimumQuality: qualities.min() ?? 0,
            meanQuality: qualities.reduce(0, +) / Double(max(qualities.count, 1)),
            maximumQuality: qualities.max() ?? 0,
            invertedElementIndices: values.filter(\.isInverted).map(\.elementIndex)
        )
    }
}
