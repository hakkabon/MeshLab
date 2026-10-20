import Foundation
import simd

/// Z-up orbit camera suitable for structural models.
public struct OrbitCamera: Sendable, Equatable {
    public var target: SIMD3<Float>
    public var distance: Float
    public var yaw: Float
    public var pitch: Float
    public var fieldOfViewY: Float
    public var nearZ: Float
    public var farZ: Float
    public var minimumDistance: Float
    public var maximumDistance: Float

    public init(
        target: SIMD3<Float> = .zero,
        distance: Float = 10,
        yaw: Float = -.pi / 4,
        pitch: Float = .pi / 6,
        fieldOfViewY: Float = 45 * .pi / 180,
        nearZ: Float = 0.01,
        farZ: Float = 10_000,
        minimumDistance: Float = 0.001,
        maximumDistance: Float = 100_000
    ) {
        self.target = target
        self.distance = distance
        self.yaw = yaw
        self.pitch = pitch
        self.fieldOfViewY = fieldOfViewY
        self.nearZ = nearZ
        self.farZ = farZ
        self.minimumDistance = minimumDistance
        self.maximumDistance = maximumDistance
    }

    public var eye: SIMD3<Float> {
        let cosPitch = cos(pitch)
        let offset = SIMD3<Float>(
            cosPitch * cos(yaw),
            cosPitch * sin(yaw),
            sin(pitch)
        )
        return target + offset * distance
    }

    public var forward: SIMD3<Float> {
        simd_normalize(target - eye)
    }

    public var right: SIMD3<Float> {
        simd_normalize(simd_cross(forward, SIMD3<Float>(0, 0, 1)))
    }

    public var up: SIMD3<Float> {
        simd_cross(right, forward)
    }

    public var viewMatrix: simd_float4x4 {
        let eye = self.eye
        let forward = self.forward
        let right = self.right
        let up = self.up

        return simd_float4x4(columns: (
            SIMD4<Float>(right.x, up.x, -forward.x, 0),
            SIMD4<Float>(right.y, up.y, -forward.y, 0),
            SIMD4<Float>(right.z, up.z, -forward.z, 0),
            SIMD4<Float>(
                -simd_dot(right, eye),
                -simd_dot(up, eye),
                simd_dot(forward, eye),
                1
            )
        ))
    }

    public func projectionMatrix(aspect: Float) -> simd_float4x4 {
        precondition(aspect > 0, "Aspect ratio must be positive")
        let yScale = 1 / tan(fieldOfViewY * 0.5)
        let xScale = yScale / aspect
        let zScale = farZ / (nearZ - farZ)
        let wzScale = zScale * nearZ

        return simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, wzScale, 0)
        ))
    }

    public func viewProjectionMatrix(aspect: Float) -> simd_float4x4 {
        projectionMatrix(aspect: aspect) * viewMatrix
    }

    public mutating func orbit(deltaX: Float, deltaY: Float) {
        yaw -= deltaX * 0.01
        pitch += deltaY * 0.01
        let limit = Float.pi * 0.495
        pitch = min(max(pitch, -limit), limit)
    }

    public mutating func zoom(by delta: Float) {
        distance *= exp(-delta * 0.01)
        distance = min(max(distance, minimumDistance), maximumDistance)
    }

    public mutating func pan(deltaX: Float, deltaY: Float, viewportHeight: Float) {
        guard viewportHeight > 0 else { return }
        let worldPerPixel = 2 * distance * tan(fieldOfViewY * 0.5) / viewportHeight
        target -= right * (deltaX * worldPerPixel)
        target += up * (deltaY * worldPerPixel)
    }

    public mutating func frame(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>,
        padding: Float = 1.35
    ) {
        let center = (minimum + maximum) * 0.5
        let radius = max(simd_length(maximum - center), 0.5)
        target = center
        distance = min(
            max(radius / max(sin(fieldOfViewY * 0.5), 0.01) * padding, minimumDistance),
            maximumDistance
        )
        nearZ = max(distance * 0.0005, 0.0001)
        farZ = max(distance * 20, 100)
    }
}
