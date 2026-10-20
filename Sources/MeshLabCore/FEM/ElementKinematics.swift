import Foundation
import simd

/// Strain-displacement (`B`) and constitutive (`D`) matrices for one element.
///
/// Both matrices are stored row-major because they are small and consumed by
/// cache-friendly local loops. `B` is `strainCount × dofCount`; `D` is
/// `strainCount × strainCount`.
public struct ElementKinematics: Sendable {
    public let elementIndex: Int
    public let elementType: ElementType
    public let nodeIndices: [Int]
    public let measure: Double
    public let dofCount: Int
    public let strainCount: Int
    public let bMatrix: [Double]
    public let constitutive: [Double]
    /// Shape-function gradients in physical coordinates. For triangles the
    /// third component is zero.
    public let shapeGradients: [SIMD3<Double>]
    private let outOfPlaneMultiplier: Double

    public static func compute(
        mesh: Mesh,
        material: ElasticMaterial,
        elementIndex: Int
    ) throws -> ElementKinematics {
        let element = mesh.elements[elementIndex]
        switch element.type {
        case .tetrahedron4:
            return try tetrahedron(
                mesh: mesh,
                material: material,
                element: element,
                elementIndex: elementIndex
            )
        case .triangle3:
            return try triangle(
                mesh: mesh,
                material: material,
                element: element,
                elementIndex: elementIndex
            )
        }
    }

    public func stiffness() -> [Double] {
        let size = dofCount
        var result = [Double](repeating: 0, count: size * size)

        for row in 0..<size {
            for column in row..<size {
                var sum = 0.0
                for first in 0..<strainCount {
                    var db = 0.0
                    for second in 0..<strainCount {
                        let d = constitutive[first * strainCount + second]
                        let b = bMatrix[second * size + column]
                        db += d * b
                    }
                    sum += bMatrix[first * size + row] * db
                }
                let value = measure * sum
                result[row * size + column] = value
                result[column * size + row] = value
            }
        }
        return result
    }

    /// Consistent mass matrix for the element, including density and measure.
    public func mass(density: Double) -> [Double] {
        precondition(density.isFinite && density >= 0, "Density must be finite and non-negative")

        let nodeCount = nodeIndices.count
        let dimension = elementType.dimension
        let denominator = nodeCount == 4 ? 20.0 : 12.0
        let factor = density * measure / denominator
        var result = [Double](repeating: 0, count: dofCount * dofCount)

        for first in 0..<nodeCount {
            for second in 0..<nodeCount {
                let coefficient = factor * (first == second ? 2 : 1)
                for axis in 0..<dimension {
                    let row = first * dimension + axis
                    let column = second * dimension + axis
                    result[row * dofCount + column] = coefficient
                }
            }
        }
        return result
    }

    /// Steady-conduction element matrix for an isotropic conductivity.
    public func thermalStiffness(conductivity: Double) -> [Double] {
        precondition(
            conductivity.isFinite && conductivity >= 0,
            "Conductivity must be finite and non-negative"
        )

        let nodeCount = nodeIndices.count
        var result = [Double](repeating: 0, count: nodeCount * nodeCount)
        let factor = conductivity * measure
        for row in 0..<nodeCount {
            for column in 0..<nodeCount {
                result[row * nodeCount + column] = factor
                    * simd_dot(shapeGradients[row], shapeGradients[column])
            }
        }
        return result
    }

    /// Recovers stress in `[σxx, σyy, σzz, τxy, τyz, τzx]` order.
    ///
    /// `initialStrain` is subtracted from the total strain before applying the
    /// constitutive matrix. Thermal analysis supplies the free thermal strain
    /// through this argument.
    public func stress(
        localDisplacement: [Double],
        initialStrain: [Double] = []
    ) -> [Double] {
        precondition(localDisplacement.count == dofCount, "Local displacement size mismatch")
        precondition(
            initialStrain.isEmpty || initialStrain.count == strainCount,
            "Initial strain size mismatch"
        )

        var strain = [Double](repeating: 0, count: strainCount)
        for row in 0..<strainCount {
            var sum = 0.0
            for column in 0..<dofCount {
                sum += bMatrix[row * dofCount + column] * localDisplacement[column]
            }
            strain[row] = sum
            if !initialStrain.isEmpty {
                strain[row] -= initialStrain[row]
            }
        }

        var inPlane = [Double](repeating: 0, count: strainCount)
        for row in 0..<strainCount {
            var sum = 0.0
            for column in 0..<strainCount {
                sum += constitutive[row * strainCount + column] * strain[column]
            }
            inPlane[row] = sum
        }

        if elementType == .tetrahedron4 {
            return inPlane
        }

        return [
            inPlane[0],
            inPlane[1],
            outOfPlaneMultiplier * (strain[0] + strain[1]),
            inPlane[2],
            0,
            0,
        ]
    }

    public static func vonMises(stress: [Double]) -> Double {
        precondition(stress.count == 6, "Stress vector must have six components")
        let xx = stress[0]
        let yy = stress[1]
        let zz = stress[2]
        let xy = stress[3]
        let yz = stress[4]
        let zx = stress[5]
        let deviatoric = 0.5 * (
            (xx - yy) * (xx - yy)
                + (yy - zz) * (yy - zz)
                + (zz - xx) * (zz - xx)
        )
        let shear = 3 * (xy * xy + yz * yz + zx * zx)
        return Foundation.sqrt(max(0, deviatoric + shear))
    }

    private static func tetrahedron(
        mesh: Mesh,
        material: ElasticMaterial,
        element: Element,
        elementIndex: Int
    ) throws -> ElementKinematics {
        let p0 = mesh.nodes[element.nodes[0]]
        let p1 = mesh.nodes[element.nodes[1]]
        let p2 = mesh.nodes[element.nodes[2]]
        let p3 = mesh.nodes[element.nodes[3]]

        let jacobian = simd_double3x3(columns: (p1 - p0, p2 - p0, p3 - p0))
        let determinant = jacobian.determinant
        let volume = abs(determinant) / 6
        guard determinant.isFinite, volume > 1e-15 else {
            throw FEMError.degenerateElement(elementIndex)
        }

        let inverseTranspose = jacobian.inverse.transpose
        let referenceGradients = [
            SIMD3<Double>(-1, -1, -1),
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, 1, 0),
            SIMD3<Double>(0, 0, 1),
        ]
        let gradients = referenceGradients.map { inverseTranspose * $0 }

        let dofCount = 12
        var bMatrix = [Double](repeating: 0, count: 6 * dofCount)
        for node in 0..<4 {
            let gradient = gradients[node]
            let offset = 3 * node

            bMatrix[0 * dofCount + offset + 0] = gradient.x
            bMatrix[1 * dofCount + offset + 1] = gradient.y
            bMatrix[2 * dofCount + offset + 2] = gradient.z
            bMatrix[3 * dofCount + offset + 0] = gradient.y
            bMatrix[3 * dofCount + offset + 1] = gradient.x
            bMatrix[4 * dofCount + offset + 1] = gradient.z
            bMatrix[4 * dofCount + offset + 2] = gradient.y
            bMatrix[5 * dofCount + offset + 0] = gradient.z
            bMatrix[5 * dofCount + offset + 2] = gradient.x
        }

        return ElementKinematics(
            elementIndex: elementIndex,
            elementType: element.type,
            nodeIndices: element.nodes,
            measure: volume,
            dofCount: dofCount,
            strainCount: 6,
            bMatrix: bMatrix,
            constitutive: material.constitutiveMatrix(for: 3),
            shapeGradients: gradients,
            outOfPlaneMultiplier: 0
        )
    }

    private static func triangle(
        mesh: Mesh,
        material: ElasticMaterial,
        element: Element,
        elementIndex: Int
    ) throws -> ElementKinematics {
        let p0 = mesh.nodes[element.nodes[0]]
        let p1 = mesh.nodes[element.nodes[1]]
        let p2 = mesh.nodes[element.nodes[2]]

        let twiceSignedArea = (p1.x - p0.x) * (p2.y - p0.y)
            - (p2.x - p0.x) * (p1.y - p0.y)
        let area = 0.5 * abs(twiceSignedArea)
        guard twiceSignedArea.isFinite, area > 1e-15 else {
            throw FEMError.degenerateElement(elementIndex)
        }
        let scale = 1 / twiceSignedArea

        let b = [
            (p1.y - p2.y) * scale,
            (p2.y - p0.y) * scale,
            (p0.y - p1.y) * scale,
        ]
        let c = [
            (p2.x - p1.x) * scale,
            (p0.x - p2.x) * scale,
            (p1.x - p0.x) * scale,
        ]

        let dofCount = 6
        var bMatrix = [Double](repeating: 0, count: 3 * dofCount)
        for node in 0..<3 {
            let offset = 2 * node
            bMatrix[0 * dofCount + offset + 0] = b[node]
            bMatrix[1 * dofCount + offset + 1] = c[node]
            bMatrix[2 * dofCount + offset + 0] = c[node]
            bMatrix[2 * dofCount + offset + 1] = b[node]
        }

        let outOfPlaneMultiplier = material.planeKinematics == .planeStrain
            ? material.lameLambda
            : 0
        let gradients = (0..<3).map { SIMD3<Double>(b[$0], c[$0], 0) }

        return ElementKinematics(
            elementIndex: elementIndex,
            elementType: element.type,
            nodeIndices: element.nodes,
            measure: area * material.thickness,
            dofCount: dofCount,
            strainCount: 3,
            bMatrix: bMatrix,
            constitutive: material.constitutiveMatrix(for: 2),
            shapeGradients: gradients,
            outOfPlaneMultiplier: outOfPlaneMultiplier
        )
    }
}
