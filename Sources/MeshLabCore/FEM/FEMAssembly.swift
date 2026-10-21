import Foundation
import simd

/// Shared assembly and boundary-condition helpers for MeshLab's 3D/2D
/// displacement and thermal formulations.
enum FEMAssembly {
    static func prescribedMap(
        _ constraints: [DirichletCondition],
        nodeCount: Int,
        dimension: Int
    ) throws -> [Int: Double] {
        var prescribed: [Int: Double] = [:]
        for condition in constraints {
            guard (0..<nodeCount).contains(condition.node) else {
                throw FEMError.invalidConstraint(dof: condition.node)
            }
            guard condition.value.isFinite else {
                throw FEMError.invalidConstraint(dof: condition.node)
            }

            let axes: [Int]
            if let axis = condition.axis {
                guard (0..<dimension).contains(axis) else {
                    throw FEMError.invalidConstraint(
                        dof: condition.node * dimension + axis
                    )
                }
                axes = [axis]
            } else {
                axes = Array(0..<dimension)
            }

            for axis in axes {
                let dof = condition.node * dimension + axis
                if let existing = prescribed[dof], existing != condition.value {
                    throw FEMError.conflictingConstraint(dof: dof)
                }
                prescribed[dof] = condition.value
            }
        }
        return prescribed
    }

    /// Every connected mesh component must have a constraint. This prevents a
    /// floating region from making the reduced system singular.
    static func validateConstraintCoverage(
        mesh: Mesh,
        prescribed: [Int: Double],
        dimension: Int
    ) throws {
        let constrainedNodes = Set(prescribed.keys.map { $0 / dimension })
        try validateComponentCoverage(
            mesh: mesh,
            constrainedNodes: constrainedNodes,
            dimension: dimension
        )
    }

    static func validateComponentCoverage(
        mesh: Mesh,
        constrainedNodes: Set<Int>,
        dimension: Int
    ) throws {
        var parent = Array(0..<mesh.nodes.count)

        func find(_ node: Int) -> Int {
            var node = node
            while parent[node] != node {
                parent[node] = parent[parent[node]]
                node = parent[node]
            }
            return node
        }

        func union(_ first: Int, _ second: Int) {
            let firstRoot = find(first)
            let secondRoot = find(second)
            if firstRoot != secondRoot {
                parent[secondRoot] = firstRoot
            }
        }

        for element in mesh.elements {
            for node in element.nodes.dropFirst() {
                union(element.nodes[0], node)
            }
        }

        var constrainedComponents = Set<Int>()
        for node in constrainedNodes {
            constrainedComponents.insert(find(node))
        }

        var unconstrainedDOFs: [Int] = []
        for node in mesh.nodes.indices where !constrainedComponents.contains(find(node)) {
            for axis in 0..<dimension {
                unconstrainedDOFs.append(node * dimension + axis)
            }
        }
        if !unconstrainedDOFs.isEmpty {
            throw FEMError.unconstrainedDegreesOfFreedom(unconstrainedDOFs)
        }
    }

    /// Builds the full external load vector, including body forces. The
    /// returned vector is not reduced for Dirichlet constraints.
    static func loadVector(_ model: FEMModel) throws -> [Double] {
        var rightHandSide = [Double](repeating: 0, count: model.mesh.dofCount)
        try applyLoads(
            model,
            dimension: model.mesh.dimension,
            into: &rightHandSide
        )
        guard model.bodyForce.x.isFinite,
              model.bodyForce.y.isFinite,
              model.bodyForce.z.isFinite else {
            throw FEMError.invalidModel("Body force must be finite")
        }
        guard model.bodyForce != .zero,
              model.material.density.isFinite,
              model.material.density > 0 else {
            return rightHandSide
        }

        let dimension = model.mesh.dimension
        for elementIndex in model.mesh.elements.indices {
            let data = try ElementKinematics.compute(
                mesh: model.mesh,
                material: model.material,
                elementIndex: elementIndex
            )
            let element = model.mesh.elements[elementIndex]
            let nodeForce = model.material.density * data.measure
                / Double(element.nodes.count)
            for node in element.nodes {
                for axis in 0..<dimension {
                    rightHandSide[node * dimension + axis] += nodeForce
                        * model.bodyForce[axis]
                }
            }
        }
        return rightHandSide
    }

    static func applyLoads(
        _ model: FEMModel,
        dimension: Int,
        into rightHandSide: inout [Double]
    ) throws {
        for load in model.loads {
            switch load {
            case .nodal(let node, let vector):
                guard (0..<model.mesh.nodes.count).contains(node) else {
                    throw FEMError.invalidLoad("Nodal load references node \(node)")
                }
                guard vector.x.isFinite, vector.y.isFinite, vector.z.isFinite else {
                    throw FEMError.invalidLoad("Nodal load has a non-finite component")
                }
                if dimension == 2, vector.z != 0 {
                    throw FEMError.invalidLoad(
                        "A two-dimensional model cannot carry an out-of-plane nodal load"
                    )
                }
                for axis in 0..<dimension {
                    rightHandSide[node * dimension + axis] += vector[axis]
                }

            case .traction(let nodes, let vector):
                guard dimension == 3 else {
                    throw FEMError.invalidLoad(
                        "Traction loads require a three-dimensional model"
                    )
                }
                guard nodes.count == 3, Set(nodes).count == 3,
                      nodes.allSatisfy({ (0..<model.mesh.nodes.count).contains($0) }) else {
                    throw FEMError.invalidLoad(
                        "A traction face needs three distinct valid nodes"
                    )
                }
                guard vector.x.isFinite, vector.y.isFinite, vector.z.isFinite else {
                    throw FEMError.invalidLoad("Traction load has a non-finite component")
                }
                let p0 = model.mesh.nodes[nodes[0]]
                let p1 = model.mesh.nodes[nodes[1]]
                let p2 = model.mesh.nodes[nodes[2]]
                let area = 0.5 * simd_length(simd_cross(p1 - p0, p2 - p0))
                guard area > 1e-15 else {
                    throw FEMError.invalidLoad("Traction face is degenerate")
                }
                let force = vector * (area / 3)
                for node in nodes {
                    let base = node * dimension
                    rightHandSide[base] += force.x
                    rightHandSide[base + 1] += force.y
                    rightHandSide[base + 2] += force.z
                }
            }
        }
    }

    static func assembleStiffness(
        _ model: FEMModel
    ) throws -> (matrix: SparseMatrix, kinematics: [ElementKinematics]) {
        var triplets: [SparseTriplet] = []
        triplets.reserveCapacity(model.mesh.elements.count * 64)
        var kinematics: [ElementKinematics] = []
        kinematics.reserveCapacity(model.mesh.elements.count)

        for elementIndex in model.mesh.elements.indices {
            let data = try ElementKinematics.compute(
                mesh: model.mesh,
                material: model.material,
                elementIndex: elementIndex
            )
            kinematics.append(data)
            appendSymmetric(
                data.stiffness(),
                size: data.dofCount,
                dofs: model.elementDOFs(elementIndex),
                scale: try model.stiffnessScale(forElement: elementIndex),
                into: &triplets
            )
        }

        let matrix = try SparseMatrix.symmetric(
            size: model.mesh.dofCount,
            lowerTriplets: triplets
        )
        return (matrix, kinematics)
    }

    static func assembleMass(
        _ model: FEMModel,
        kinematics: [ElementKinematics]
    ) throws -> SparseMatrix {
        guard model.material.density.isFinite, model.material.density > 0 else {
            throw FEMError.invalidModel(
                "Modal and transient analysis require positive material density"
            )
        }

        var triplets: [SparseTriplet] = []
        triplets.reserveCapacity(model.mesh.elements.count * 64)
        for data in kinematics {
            appendSymmetric(
                data.mass(density: model.material.density),
                size: data.dofCount,
                dofs: model.elementDOFs(data.elementIndex),
                into: &triplets
            )
        }
        return try SparseMatrix.symmetric(
            size: model.mesh.dofCount,
            lowerTriplets: triplets
        )
    }

    static func appendSymmetric(
        _ local: [Double],
        size: Int,
        dofs: [Int],
        scale: Double = 1,
        into triplets: inout [SparseTriplet]
    ) {
        for row in 0..<size {
            for column in 0...row {
                let value = local[row * size + column] * scale
                guard value != 0 else { continue }
                triplets.append(SparseTriplet(
                    row: dofs[row],
                    column: dofs[column],
                    value: value
                ))
            }
        }
    }

    /// Builds the equivalent thermal load `∫ Bᵀ D εth dV` and returns the
    /// element-local thermal strain vectors.
    static func thermalLoads(
        _ model: FEMModel,
        kinematics: [ElementKinematics]
    ) throws -> (loads: [Double], strains: [[Double]]) {
        var loads = [Double](repeating: 0, count: model.mesh.dofCount)
        guard !model.temperatureChange.isEmpty else {
            return (loads, Array(repeating: [], count: kinematics.count))
        }
        guard model.mesh.dimension == 3 else {
            throw FEMError.invalidModel(
                "Thermal stress coupling currently requires a three-dimensional mesh"
            )
        }
        guard model.temperatureChange.count == model.mesh.nodes.count else {
            throw FEMError.invalidModel(
                "Temperature change must provide one value per mesh node"
            )
        }
        guard model.temperatureChange.allSatisfy(\.isFinite) else {
            throw FEMError.invalidModel("Temperature change contains a non-finite value")
        }
        guard model.material.thermalExpansion.isFinite,
              model.material.thermalExpansion >= 0 else {
            throw FEMError.invalidModel("Material thermal expansion is invalid")
        }

        var strains: [[Double]] = []
        strains.reserveCapacity(kinematics.count)
        let expansion = model.material.thermalExpansion

        for data in kinematics {
            let change = data.nodeIndices.reduce(0.0) {
                $0 + model.temperatureChange[$1]
            } / Double(data.nodeIndices.count)
            var strain = [Double](repeating: 0, count: data.strainCount)
            for axis in 0..<model.mesh.dimension {
                strain[axis] = expansion * change
            }
            strains.append(strain)

            let dofs = model.elementDOFs(data.elementIndex)
            for row in 0..<data.dofCount {
                var sum = 0.0
                for strainIndex in 0..<data.strainCount {
                    var db = 0.0
                    for column in 0..<data.strainCount {
                        db += data.constitutive[strainIndex * data.strainCount + column]
                            * strain[column]
                    }
                    sum += data.bMatrix[strainIndex * data.dofCount + row] * db
                }
                loads[dofs[row]] += data.measure * sum
            }
        }
        return (loads, strains)
    }

    static func freeDOFs(
        count: Int,
        prescribed: [Int: Double]
    ) throws -> [Int] {
        let free = (0..<count).filter { prescribed[$0] == nil }
        guard !free.isEmpty else {
            throw FEMError.noFreeDegreesOfFreedom
        }
        return free
    }

    static func reduced(
        _ matrix: SparseMatrix,
        freeDOFs: [Int]
    ) throws -> SparseMatrix {
        var reducedIndex = [Int](repeating: -1, count: matrix.rowCount)
        for (index, dof) in freeDOFs.enumerated() {
            reducedIndex[dof] = index
        }

        var triplets: [SparseTriplet] = []
        for row in 0..<matrix.rowCount {
            let reducedRow = reducedIndex[row]
            guard reducedRow >= 0 else { continue }
            for index in matrix.rowStarts[row]..<matrix.rowStarts[row + 1] {
                let column = Int(matrix.columnIndices[index])
                let reducedColumn = reducedIndex[column]
                guard reducedColumn >= 0 else { continue }
                triplets.append(SparseTriplet(
                    row: reducedRow,
                    column: reducedColumn,
                    value: matrix.values[index]
                ))
            }
        }
        return try SparseMatrix.symmetric(
            size: freeDOFs.count,
            lowerTriplets: triplets
        )
    }

    static func reduced(
        _ vector: [Double],
        freeDOFs: [Int]
    ) -> [Double] {
        freeDOFs.map { vector[$0] }
    }

    /// Reduces a right-hand side while accounting for nonzero prescribed
    /// values through `rhs_f - K_fc x_c`.
    static func reducedLoads(
        matrix: SparseMatrix,
        rightHandSide: [Double],
        freeDOFs: [Int],
        prescribed: [Int: Double]
    ) -> [Double] {
        guard !prescribed.isEmpty else {
            return reduced(rightHandSide, freeDOFs: freeDOFs)
        }
        var prescribedVector = [Double](repeating: 0, count: matrix.rowCount)
        for (dof, value) in prescribed {
            prescribedVector[dof] = value
        }
        let product = matrix.multiply(prescribedVector)
        return freeDOFs.map { rightHandSide[$0] - product[$0] }
    }

    static func full(
        _ vector: [Double],
        freeDOFs: [Int],
        count: Int
    ) -> [Double] {
        var result = [Double](repeating: 0, count: count)
        for (index, dof) in freeDOFs.enumerated() {
            result[dof] = vector[index]
        }
        return result
    }
}
