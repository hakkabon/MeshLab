import Foundation
import MeshLabCore
import simd

public struct RenderOptions: Sendable, Equatable {
    public var showStress: Bool
    public var deformationScale: Float
    public var lightDirection: SIMD3<Float>

    public init(
        showStress: Bool = true,
        deformationScale: Float = 1,
        lightDirection: SIMD3<Float> = SIMD3<Float>(-0.35, -0.55, -0.75)
    ) {
        self.showStress = showStress
        self.deformationScale = deformationScale
        self.lightDirection = lightDirection
    }
}

/// CPU-side data consumed by ``FEMRenderer``.
///
/// Displacements and stresses are already gathered into surface-vertex order,
/// so the renderer can write them straight into shared `MTLBuffer` memory
/// without an intermediate layout conversion.
public struct RenderScene: Sendable {
    public let surface: SurfaceMesh
    public let displacements: [SIMD3<Float>]
    public let stress: [Float]
    public let stressRange: ClosedRange<Float>
    public let revision: Int

    public init(
        surface: SurfaceMesh,
        result: StaticResult,
        revision: Int = 1
    ) {
        self.surface = surface
        self.displacements = surface.sourceNodes.map { node in
            let displacement = result.displacements[node]
            return SIMD3<Float>(
                Float(displacement.x),
                Float(displacement.y),
                Float(displacement.z)
            )
        }
        self.stress = surface.sourceNodes.map { Float(result.nodalVonMises[$0]) }

        let minimum = self.stress.min() ?? 0
        let maximum = self.stress.max() ?? 0
        self.stressRange = minimum...maximum
        self.revision = revision
    }

    public init(surface: SurfaceMesh, revision: Int = 0) {
        self.surface = surface
        self.displacements = [SIMD3<Float>](
            repeating: .zero,
            count: surface.positions.count
        )
        self.stress = [Float](repeating: 0, count: surface.positions.count)
        self.stressRange = 0...1
        self.revision = revision
    }

    public var isEmpty: Bool {
        surface.positions.isEmpty
    }
}
