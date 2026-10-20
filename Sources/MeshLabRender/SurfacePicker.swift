import CoreGraphics
import Foundation
import MeshLabCore
import simd

/// A surface node selected by a viewport click or tap.
public struct SurfacePick: Sendable, Equatable {
    public let surfaceVertex: Int
    public let sourceNode: Int
    public let triangleIndex: Int
    public let position: SIMD3<Float>
    public let barycentric: SIMD3<Float>

    public init(
        surfaceVertex: Int,
        sourceNode: Int,
        triangleIndex: Int,
        position: SIMD3<Float>,
        barycentric: SIMD3<Float>
    ) {
        self.surfaceVertex = surfaceVertex
        self.sourceNode = sourceNode
        self.triangleIndex = triangleIndex
        self.position = position
        self.barycentric = barycentric
    }
}

/// CPU ray picking against the deformed render surface.
public enum SurfacePicker {
    public static func pick(
        surface: SurfaceMesh,
        displacements: [SIMD3<Float>] = [],
        deformationScale: Float = 1,
        point: CGPoint,
        viewSize: CGSize,
        camera: OrbitCamera,
        originTopLeft: Bool = true
    ) -> SurfacePick? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        guard surface.indices.count >= 3 else { return nil }
        if !displacements.isEmpty, displacements.count != surface.positions.count {
            return nil
        }

        let aspect = Float(viewSize.width / viewSize.height)
        let inverseViewProjection = simd_inverse(camera.viewProjectionMatrix(aspect: aspect))
        let ndcX = Float(point.x / viewSize.width) * 2 - 1
        let ndcY = originTopLeft
            ? 1 - Float(point.y / viewSize.height) * 2
            : Float(point.y / viewSize.height) * 2 - 1

        let near = unproject(
            SIMD4<Float>(ndcX, ndcY, 0, 1),
            using: inverseViewProjection
        )
        let far = unproject(
            SIMD4<Float>(ndcX, ndcY, 1, 1),
            using: inverseViewProjection
        )
        let direction = simd_normalize(far - near)

        var best: (distance: Float, triangle: Int, barycentric: SIMD3<Float>)?
        var triangle = 0
        while triangle + 2 < surface.indices.count {
            let i0 = Int(surface.indices[triangle])
            let i1 = Int(surface.indices[triangle + 1])
            let i2 = Int(surface.indices[triangle + 2])
            guard i0 < surface.positions.count,
                  i1 < surface.positions.count,
                  i2 < surface.positions.count else {
                triangle += 3
                continue
            }

            let p0 = deformedVertex(
                i0,
                surface: surface,
                displacements: displacements,
                scale: deformationScale
            )
            let p1 = deformedVertex(
                i1,
                surface: surface,
                displacements: displacements,
                scale: deformationScale
            )
            let p2 = deformedVertex(
                i2,
                surface: surface,
                displacements: displacements,
                scale: deformationScale
            )

            if let hit = intersect(origin: near, direction: direction, p0: p0, p1: p1, p2: p2) {
                if best == nil || hit.distance < best!.distance {
                    best = (hit.distance, triangle / 3, hit.barycentric)
                }
            }
            triangle += 3
        }

        guard let best else { return nil }
        let base = best.triangle * 3
        let vertices = [
            Int(surface.indices[base]),
            Int(surface.indices[base + 1]),
            Int(surface.indices[base + 2]),
        ]
        let weights = [
            best.barycentric.x,
            best.barycentric.y,
            best.barycentric.z,
        ]
        let nearest = weights.indices.max { weights[$0] < weights[$1] } ?? 0
        let surfaceVertex = vertices[nearest]
        guard surfaceVertex < surface.sourceNodes.count else { return nil }
        let position = deformedVertex(
            surfaceVertex,
            surface: surface,
            displacements: displacements,
            scale: deformationScale
        )

        return SurfacePick(
            surfaceVertex: surfaceVertex,
            sourceNode: surface.sourceNodes[surfaceVertex],
            triangleIndex: best.triangle,
            position: position,
            barycentric: best.barycentric
        )
    }

    private static func deformedVertex(
        _ index: Int,
        surface: SurfaceMesh,
        displacements: [SIMD3<Float>],
        scale: Float
    ) -> SIMD3<Float> {
        let displacement = displacements.isEmpty ? .zero : displacements[index]
        return surface.positions[index] + displacement * scale
    }

    private static func unproject(
        _ clip: SIMD4<Float>,
        using inverseViewProjection: simd_float4x4
    ) -> SIMD3<Float> {
        let world = inverseViewProjection * clip
        return SIMD3<Float>(world.x, world.y, world.z) / world.w
    }

    private static func intersect(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        p0: SIMD3<Float>,
        p1: SIMD3<Float>,
        p2: SIMD3<Float>
    ) -> (distance: Float, barycentric: SIMD3<Float>)? {
        let epsilon: Float = 1e-7
        let edge1 = p1 - p0
        let edge2 = p2 - p0
        let h = simd_cross(direction, edge2)
        let determinant = simd_dot(edge1, h)
        guard abs(determinant) > epsilon else { return nil }

        let inverseDeterminant = 1 / determinant
        let s = origin - p0
        let u = inverseDeterminant * simd_dot(s, h)
        guard u >= 0, u <= 1 else { return nil }

        let q = simd_cross(s, edge1)
        let v = inverseDeterminant * simd_dot(direction, q)
        guard v >= 0, u + v <= 1 else { return nil }

        let distance = inverseDeterminant * simd_dot(edge2, q)
        guard distance > epsilon else { return nil }

        return (
            distance,
            SIMD3<Float>(1 - u - v, u, v)
        )
    }
}
