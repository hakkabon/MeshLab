import Foundation
import simd

public enum StructuralDegreeOfFreedom: Int, Sendable, Hashable, Codable, CaseIterable {
    case translationX, translationY, translationZ
    case rotationX, rotationY, rotationZ
}

public enum StructuralElementError: Error, Equatable, Sendable {
    case invalidGeometry
    case invalidProperties
    case invalidDegreeOfFreedomMap
}

/// Two-node, planar Euler-Bernoulli frame element. The returned contribution
/// uses `[ux, uy, rz]` at each node and can be assembled with continuum or
/// other mixed-DOF contributions through `FEMElementOperator`.
public struct EulerBernoulliFrame2D: Sendable, Hashable {
    public var youngModulus: Double
    public var area: Double
    public var secondMoment: Double

    public init(youngModulus: Double, area: Double, secondMoment: Double) {
        self.youngModulus = youngModulus
        self.area = area
        self.secondMoment = secondMoment
    }

    public func stiffnessContribution(
        first: SIMD2<Double>,
        second: SIMD2<Double>,
        degreesOfFreedom: [Int]
    ) throws -> FEMElementContribution {
        guard youngModulus.isFinite, youngModulus > 0,
              area.isFinite, area > 0,
              secondMoment.isFinite, secondMoment > 0 else {
            throw StructuralElementError.invalidProperties
        }
        guard degreesOfFreedom.count == 6, Set(degreesOfFreedom).count == 6 else {
            throw StructuralElementError.invalidDegreeOfFreedomMap
        }
        let delta = second - first
        let length = simd_length(delta)
        guard length.isFinite, length > 0 else { throw StructuralElementError.invalidGeometry }
        let c = delta.x / length
        let s = delta.y / length
        let axial = youngModulus * area / length
        let bending = youngModulus * secondMoment
        let l2 = length * length
        let l3 = l2 * length
        var local = [Double](repeating: 0, count: 36)
        func put(_ row: Int, _ column: Int, _ value: Double) {
            local[row * 6 + column] = value
            local[column * 6 + row] = value
        }
        put(0, 0, axial); put(0, 3, -axial); put(3, 3, axial)
        put(1, 1, 12 * bending / l3)
        put(1, 2, 6 * bending / l2)
        put(1, 4, -12 * bending / l3)
        put(1, 5, 6 * bending / l2)
        put(2, 2, 4 * bending / length)
        put(2, 4, -6 * bending / l2)
        put(2, 5, 2 * bending / length)
        put(4, 4, 12 * bending / l3)
        put(4, 5, -6 * bending / l2)
        put(5, 5, 4 * bending / length)

        let transform = [
            c, s, 0, 0, 0, 0,
            -s, c, 0, 0, 0, 0,
            0, 0, 1, 0, 0, 0,
            0, 0, 0, c, s, 0,
            0, 0, 0, -s, c, 0,
            0, 0, 0, 0, 0, 1,
        ]
        var global = [Double](repeating: 0, count: 36)
        for row in 0..<6 {
            for column in 0..<6 {
                var value = 0.0
                for i in 0..<6 {
                    for j in 0..<6 {
                        value += transform[i * 6 + row] * local[i * 6 + j]
                            * transform[j * 6 + column]
                    }
                }
                global[row * 6 + column] = value
            }
        }
        return try FEMElementContribution(
            degreesOfFreedom: degreesOfFreedom,
            matrix: global
        )
    }
}

/// Three-node constant-strain membrane embedded in 3D. This is the membrane
/// component of a shell formulation; it intentionally has no transverse
/// bending stiffness or rotational degrees of freedom.
public struct TriangularMembraneShell3D: Sendable, Hashable {
    public var youngModulus: Double
    public var poissonRatio: Double
    public var thickness: Double

    public init(youngModulus: Double, poissonRatio: Double, thickness: Double) {
        self.youngModulus = youngModulus
        self.poissonRatio = poissonRatio
        self.thickness = thickness
    }

    public func stiffnessContribution(
        nodes: [SIMD3<Double>],
        degreesOfFreedom: [Int]
    ) throws -> FEMElementContribution {
        guard youngModulus.isFinite, youngModulus > 0,
              poissonRatio.isFinite, poissonRatio > -1, poissonRatio < 0.5,
              thickness.isFinite, thickness > 0 else {
            throw StructuralElementError.invalidProperties
        }
        guard nodes.count == 3, degreesOfFreedom.count == 9,
              Set(degreesOfFreedom).count == 9 else {
            throw StructuralElementError.invalidDegreeOfFreedomMap
        }
        let firstEdge = nodes[1] - nodes[0]
        let secondEdge = nodes[2] - nodes[0]
        let twiceArea = simd_length(simd_cross(firstEdge, secondEdge))
        guard twiceArea.isFinite, twiceArea > 1e-15 else {
            throw StructuralElementError.invalidGeometry
        }
        let e1 = simd_normalize(firstEdge)
        let normal = simd_normalize(simd_cross(firstEdge, secondEdge))
        let e2 = simd_cross(normal, e1)
        let x = [0.0, simd_length(firstEdge), simd_dot(secondEdge, e1)]
        let y = [0.0, 0.0, simd_dot(secondEdge, e2)]
        let signedTwiceArea = x[1] * y[2]
        let b = [y[1] - y[2], y[2] - y[0], y[0] - y[1]]
        let c = [x[2] - x[1], x[0] - x[2], x[1] - x[0]]
        var strain = [Double](repeating: 0, count: 18)
        for node in 0..<3 {
            strain[node * 2] = b[node] / signedTwiceArea
            strain[6 + node * 2 + 1] = c[node] / signedTwiceArea
            strain[12 + node * 2] = c[node] / signedTwiceArea
            strain[12 + node * 2 + 1] = b[node] / signedTwiceArea
        }
        let factor = youngModulus / (1 - poissonRatio * poissonRatio)
        let constitutive = [
            factor, factor * poissonRatio, 0,
            factor * poissonRatio, factor, 0,
            0, 0, factor * (1 - poissonRatio) / 2,
        ]
        var local = [Double](repeating: 0, count: 36)
        let scale = thickness * twiceArea / 2
        for row in 0..<6 {
            for column in 0..<6 {
                var value = 0.0
                for i in 0..<3 {
                    for j in 0..<3 {
                        value += strain[i * 6 + row] * constitutive[i * 3 + j]
                            * strain[j * 6 + column]
                    }
                }
                local[row * 6 + column] = scale * value
            }
        }
        var transform = [Double](repeating: 0, count: 54)
        for node in 0..<3 {
            for axis in 0..<3 {
                transform[(node * 2) * 9 + node * 3 + axis] = e1[axis]
                transform[(node * 2 + 1) * 9 + node * 3 + axis] = e2[axis]
            }
        }
        var global = [Double](repeating: 0, count: 81)
        for row in 0..<9 {
            for column in 0..<9 {
                var value = 0.0
                for i in 0..<6 {
                    for j in 0..<6 {
                        value += transform[i * 9 + row] * local[i * 6 + j]
                            * transform[j * 9 + column]
                    }
                }
                global[row * 9 + column] = value
            }
        }
        return try FEMElementContribution(
            degreesOfFreedom: degreesOfFreedom,
            matrix: global
        )
    }
}
