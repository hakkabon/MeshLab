import Foundation
import simd

public struct ElementIntegrationPoint: Sendable {
    public let shapeValues: [Double]
    public let shapeGradients: [SIMD3<Double>]
    public let bMatrix: [Double]
    public let weightedMeasure: Double
}

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
    public let integrationPoints: [ElementIntegrationPoint]
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
        case .tetrahedron10:
            return try tetrahedron10(
                mesh: mesh,
                material: material,
                element: element,
                elementIndex: elementIndex
            )
        case .hexahedron8:
            return try hexahedron8(
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

        for point in integrationPoints {
            for row in 0..<size {
                for column in row..<size {
                    var sum = 0.0
                    for first in 0..<strainCount {
                        var db = 0.0
                        for second in 0..<strainCount {
                            let d = constitutive[first * strainCount + second]
                            let b = point.bMatrix[second * size + column]
                            db += d * b
                        }
                        sum += point.bMatrix[first * size + row] * db
                    }
                    let value = point.weightedMeasure * sum
                    result[row * size + column] += value
                    if row != column { result[column * size + row] += value }
                }
            }
        }
        return result
    }

    /// Consistent mass matrix for the element, including density and measure.
    public func mass(density: Double) -> [Double] {
        precondition(density.isFinite && density >= 0, "Density must be finite and non-negative")

        let nodeCount = nodeIndices.count
        let dimension = elementType.dimension
        var result = [Double](repeating: 0, count: dofCount * dofCount)

        // A one-point rule is exact for the linear-simplex stiffness but not
        // for the quadratic N_i N_j terms in a consistent mass matrix. Keep
        // the closed-form simplex rule instead of silently reducing the
        // dynamic system to a rank-deficient centroid mass.
        if elementType == .tetrahedron4 || elementType == .triangle3 {
            let denominator = elementType == .tetrahedron4 ? 20.0 : 12.0
            let coefficient = density * measure / denominator
            for first in 0..<nodeCount {
                for second in 0..<nodeCount {
                    let value = coefficient * (first == second ? 2 : 1)
                    for axis in 0..<dimension {
                        let row = first * dimension + axis
                        let column = second * dimension + axis
                        result[row * dofCount + column] = value
                    }
                }
            }
            return result
        }

        for point in integrationPoints {
            for first in 0..<nodeCount {
                for second in 0..<nodeCount {
                    let coefficient = density * point.weightedMeasure
                        * point.shapeValues[first] * point.shapeValues[second]
                    for axis in 0..<dimension {
                        let row = first * dimension + axis
                        let column = second * dimension + axis
                        result[row * dofCount + column] += coefficient
                    }
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
        for point in integrationPoints {
            let factor = conductivity * point.weightedMeasure
            for row in 0..<nodeCount {
                for column in 0..<nodeCount {
                    result[row * nodeCount + column] += factor
                        * simd_dot(point.shapeGradients[row], point.shapeGradients[column])
                }
            }
        }
        return result
    }

    public func nodalMeasureWeights() -> [Double] {
        var result = [Double](repeating: 0, count: nodeIndices.count)
        for point in integrationPoints {
            for node in result.indices {
                result[node] += point.shapeValues[node] * point.weightedMeasure
            }
        }
        return result
    }

    public func averageGradient(nodalValues: [Double]) -> SIMD3<Double> {
        precondition(nodalValues.count == nodeIndices.count)
        var result = SIMD3<Double>.zero
        for point in integrationPoints {
            var gradient = SIMD3<Double>.zero
            for node in nodalValues.indices {
                gradient += point.shapeGradients[node] * nodalValues[node]
            }
            result += gradient * (point.weightedMeasure / measure)
        }
        return result
    }

    public func internalForce(
        localDisplacement: [Double],
        initialStrain: [Double] = []
    ) -> [Double] {
        var result = [Double](repeating: 0, count: dofCount)
        for point in integrationPoints {
            let strain = elasticStrain(
                localDisplacement: localDisplacement,
                initialStrain: initialStrain,
                bMatrix: point.bMatrix
            )
            var conjugate = [Double](repeating: 0, count: strainCount)
            for row in 0..<strainCount {
                for column in 0..<strainCount {
                    conjugate[row] += constitutive[row * strainCount + column]
                        * strain[column]
                }
            }
            for localDOF in 0..<dofCount {
                for component in 0..<strainCount {
                    result[localDOF] += point.bMatrix[
                        component * dofCount + localDOF
                    ] * conjugate[component] * point.weightedMeasure
                }
            }
        }
        return result
    }

    public func equivalentInitialStrainLoad(_ initialStrain: [Double]) -> [Double] {
        precondition(initialStrain.count == strainCount)
        let zero = [Double](repeating: 0, count: dofCount)
        return internalForce(localDisplacement: zero, initialStrain: initialStrain)
            .map(-)
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
        var averaged = [Double](repeating: 0, count: 6)
        for point in integrationPoints {
            let strain = elasticStrain(
                localDisplacement: localDisplacement,
                initialStrain: initialStrain,
                bMatrix: point.bMatrix
            )
            var conjugate = [Double](repeating: 0, count: strainCount)
            for row in 0..<strainCount {
                for column in 0..<strainCount {
                    conjugate[row] += constitutive[row * strainCount + column]
                        * strain[column]
                }
            }
            let components = elementType.dimension == 3 ? conjugate : [
                conjugate[0], conjugate[1],
                outOfPlaneMultiplier * (strain[0] + strain[1]),
                conjugate[2], 0, 0,
            ]
            for index in 0..<6 {
                averaged[index] += components[index] * point.weightedMeasure / measure
            }
        }
        return averaged
    }

    /// Elastic energy stored by this element after subtracting any initial
    /// strain, before an optional material/stiffness multiplier is applied.
    public func strainEnergy(
        localDisplacement: [Double],
        initialStrain: [Double] = []
    ) -> Double {
        var quadratic = 0.0
        for point in integrationPoints {
            let strain = elasticStrain(
                localDisplacement: localDisplacement,
                initialStrain: initialStrain,
                bMatrix: point.bMatrix
            )
            var local = 0.0
            for row in 0..<strainCount {
                var stress = 0.0
                for column in 0..<strainCount {
                    stress += constitutive[row * strainCount + column] * strain[column]
                }
                local += strain[row] * stress
            }
            quadratic += point.weightedMeasure * local
        }
        return 0.5 * quadratic
    }

    private func elasticStrain(
        localDisplacement: [Double],
        initialStrain: [Double],
        bMatrix: [Double]
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

        return strain
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
        let edges = [p1 - p0, p2 - p0, p3 - p0, p2 - p1, p3 - p1, p3 - p2]
        let scale = edges.map(simd_length).max() ?? 0
        let quality = scale > 0 ? abs(determinant) / (scale * scale * scale) : 0
        guard determinant.isFinite, volume > 0, quality > 1e-12 else {
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
            integrationPoints: [ElementIntegrationPoint(
                shapeValues: [Double](repeating: 0.25, count: 4),
                shapeGradients: gradients,
                bMatrix: bMatrix,
                weightedMeasure: volume
            )],
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
        let firstLength = hypot(p1.x - p0.x, p1.y - p0.y)
        let secondLength = hypot(p2.x - p0.x, p2.y - p0.y)
        let thirdLength = hypot(p2.x - p1.x, p2.y - p1.y)
        let edgeScale = max(firstLength, secondLength, thirdLength)
        let quality = edgeScale > 0
            ? abs(twiceSignedArea) / (edgeScale * edgeScale)
            : 0
        guard twiceSignedArea.isFinite, area > 0, quality > 1e-12 else {
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
            integrationPoints: [ElementIntegrationPoint(
                shapeValues: [Double](repeating: 1.0 / 3.0, count: 3),
                shapeGradients: gradients,
                bMatrix: bMatrix,
                weightedMeasure: area * material.thickness
            )],
            outOfPlaneMultiplier: outOfPlaneMultiplier
        )
    }

    private static func tetrahedron10(
        mesh: Mesh,
        material: ElasticMaterial,
        element: Element,
        elementIndex: Int
    ) throws -> ElementKinematics {
        let coordinates = element.nodes.map { mesh.nodes[$0] }
        // A tensor Gauss rule mapped to the reference tetrahedron through a
        // Duffy transform. Four points per axis integrate the quadratic
        // shape-function mass products without the rank deficiency of the
        // common four-point stiffness rule and also supports curved geometry.
        let gauss = [
            (0.06943184420297371, 0.1739274225687269),
            (0.33000947820757187, 0.32607257743127305),
            (0.6699905217924281, 0.32607257743127305),
            (0.9305681557970262, 0.1739274225687269),
        ]
        var points: [ElementIntegrationPoint] = []
        points.reserveCapacity(64)
        for (u, wu) in gauss {
            for (v, wv) in gauss {
                for (w, ww) in gauss {
                    let l2 = u
                    let l3 = (1 - u) * v
                    let l4 = (1 - u) * (1 - v) * w
                    let l1 = 1 - l2 - l3 - l4
                    let shape = [
                        l1 * (2 * l1 - 1), l2 * (2 * l2 - 1),
                        l3 * (2 * l3 - 1), l4 * (2 * l4 - 1),
                        4 * l1 * l2, 4 * l2 * l3, 4 * l3 * l1,
                        4 * l1 * l4, 4 * l2 * l4, 4 * l3 * l4,
                    ]
                    let barycentricGradients = [
                        SIMD3<Double>(-1, -1, -1), SIMD3<Double>(1, 0, 0),
                        SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, 0, 1),
                    ]
                    let ls = [l1, l2, l3, l4]
                    var natural = (0..<4).map {
                        barycentricGradients[$0] * (4 * ls[$0] - 1)
                    }
                    natural.append(4 * (l1 * barycentricGradients[1] + l2 * barycentricGradients[0]))
                    natural.append(4 * (l2 * barycentricGradients[2] + l3 * barycentricGradients[1]))
                    natural.append(4 * (l3 * barycentricGradients[0] + l1 * barycentricGradients[2]))
                    natural.append(4 * (l1 * barycentricGradients[3] + l4 * barycentricGradients[0]))
                    natural.append(4 * (l2 * barycentricGradients[3] + l4 * barycentricGradients[1]))
                    natural.append(4 * (l3 * barycentricGradients[3] + l4 * barycentricGradients[2]))
                    points.append(try integrationPoint3D(
                        coordinates: coordinates,
                        shapeValues: shape,
                        naturalGradients: natural,
                        referenceWeight: wu * wv * ww * (1 - u) * (1 - u) * (1 - v),
                        elementIndex: elementIndex
                    ))
                }
            }
        }
        return integratedSolid(
            element: element,
            elementIndex: elementIndex,
            material: material,
            points: points
        )
    }

    private static func hexahedron8(
        mesh: Mesh,
        material: ElasticMaterial,
        element: Element,
        elementIndex: Int
    ) throws -> ElementKinematics {
        let coordinates = element.nodes.map { mesh.nodes[$0] }
        let signs = [
            SIMD3<Double>(-1, -1, -1), SIMD3<Double>(1, -1, -1),
            SIMD3<Double>(1, 1, -1), SIMD3<Double>(-1, 1, -1),
            SIMD3<Double>(-1, -1, 1), SIMD3<Double>(1, -1, 1),
            SIMD3<Double>(1, 1, 1), SIMD3<Double>(-1, 1, 1),
        ]
        let g = 1 / sqrt(3.0)
        var points: [ElementIntegrationPoint] = []
        for r in [-g, g] {
            for s in [-g, g] {
                for t in [-g, g] {
                    var shape: [Double] = []
                    var natural: [SIMD3<Double>] = []
                    for sign in signs {
                        shape.append(
                            0.125 * (1 + sign.x * r)
                                * (1 + sign.y * s) * (1 + sign.z * t)
                        )
                        natural.append(SIMD3<Double>(
                            0.125 * sign.x * (1 + sign.y * s) * (1 + sign.z * t),
                            0.125 * sign.y * (1 + sign.x * r) * (1 + sign.z * t),
                            0.125 * sign.z * (1 + sign.x * r) * (1 + sign.y * s)
                        ))
                    }
                    points.append(try integrationPoint3D(
                        coordinates: coordinates,
                        shapeValues: shape,
                        naturalGradients: natural,
                        referenceWeight: 1,
                        elementIndex: elementIndex
                    ))
                }
            }
        }
        return integratedSolid(
            element: element,
            elementIndex: elementIndex,
            material: material,
            points: points
        )
    }

    private static func integrationPoint3D(
        coordinates: [SIMD3<Double>],
        shapeValues: [Double],
        naturalGradients: [SIMD3<Double>],
        referenceWeight: Double,
        elementIndex: Int
    ) throws -> ElementIntegrationPoint {
        var jacobian = simd_double3x3(columns: (.zero, .zero, .zero))
        for node in coordinates.indices {
            jacobian.columns.0 += coordinates[node] * naturalGradients[node].x
            jacobian.columns.1 += coordinates[node] * naturalGradients[node].y
            jacobian.columns.2 += coordinates[node] * naturalGradients[node].z
        }
        let determinant = jacobian.determinant
        guard determinant.isFinite, determinant > 1e-15 else {
            throw FEMError.degenerateElement(elementIndex)
        }
        let gradients = naturalGradients.map { jacobian.inverse.transpose * $0 }
        return ElementIntegrationPoint(
            shapeValues: shapeValues,
            shapeGradients: gradients,
            bMatrix: solidBMatrix(gradients),
            weightedMeasure: determinant * referenceWeight
        )
    }

    private static func integratedSolid(
        element: Element,
        elementIndex: Int,
        material: ElasticMaterial,
        points: [ElementIntegrationPoint]
    ) -> ElementKinematics {
        let measure = points.reduce(0) { $0 + $1.weightedMeasure }
        let nodeCount = element.nodes.count
        var averageGradients = [SIMD3<Double>](repeating: .zero, count: nodeCount)
        var averageB = [Double](repeating: 0, count: 6 * nodeCount * 3)
        for point in points {
            let fraction = point.weightedMeasure / measure
            for node in 0..<nodeCount {
                averageGradients[node] += point.shapeGradients[node] * fraction
            }
            for index in averageB.indices {
                averageB[index] += point.bMatrix[index] * fraction
            }
        }
        return ElementKinematics(
            elementIndex: elementIndex,
            elementType: element.type,
            nodeIndices: element.nodes,
            measure: measure,
            dofCount: nodeCount * 3,
            strainCount: 6,
            bMatrix: averageB,
            constitutive: material.constitutiveMatrix(for: 3),
            shapeGradients: averageGradients,
            integrationPoints: points,
            outOfPlaneMultiplier: 0
        )
    }

    private static func solidBMatrix(_ gradients: [SIMD3<Double>]) -> [Double] {
        let dofCount = gradients.count * 3
        var result = [Double](repeating: 0, count: 6 * dofCount)
        for (node, gradient) in gradients.enumerated() {
            let offset = node * 3
            result[0 * dofCount + offset] = gradient.x
            result[1 * dofCount + offset + 1] = gradient.y
            result[2 * dofCount + offset + 2] = gradient.z
            result[3 * dofCount + offset] = gradient.y
            result[3 * dofCount + offset + 1] = gradient.x
            result[4 * dofCount + offset + 1] = gradient.z
            result[4 * dofCount + offset + 2] = gradient.y
            result[5 * dofCount + offset] = gradient.z
            result[5 * dofCount + offset + 2] = gradient.x
        }
        return result
    }
}
