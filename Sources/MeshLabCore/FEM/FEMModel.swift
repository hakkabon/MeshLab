import Foundation
import simd

public struct DirichletCondition: Sendable, Hashable {
    /// Node index in the mesh.
    public let node: Int
    /// Component axis (`0...dimension-1`), or `nil` to constrain all axes.
    public let axis: Int?
    public let value: Double

    public init(node: Int, axis: Int? = nil, value: Double = 0) {
        self.node = node
        self.axis = axis
        self.value = value
    }

    public static func fixed(node: Int) -> DirichletCondition {
        DirichletCondition(node: node)
    }

    public static func fixed(node: Int, axis: Int) -> DirichletCondition {
        DirichletCondition(node: node, axis: axis)
    }
}

public enum Load: Sendable, Hashable {
    /// Point load at a node.
    case nodal(node: Int, vector: SIMD3<Double>)
    /// Uniform traction on a triangular face (`nodes` must contain three
    /// distinct node indices). The total force is `traction * area`.
    case traction(nodes: [Int], vector: SIMD3<Double>)
}

/// A linear-elastic finite-element model.
public struct FEMModel: Sendable {
    public var mesh: Mesh
    public var material: ElasticMaterial
    public var constraints: [DirichletCondition]
    public var loads: [Load]
    /// Acceleration applied to every element, typically gravity. The
    /// distributed force is `density * bodyForce * measure`.
    public var bodyForce: SIMD3<Double>

    public init(
        mesh: Mesh,
        material: ElasticMaterial,
        constraints: [DirichletCondition],
        loads: [Load] = [],
        bodyForce: SIMD3<Double> = .zero
    ) {
        self.mesh = mesh
        self.material = material
        self.constraints = constraints
        self.loads = loads
        self.bodyForce = bodyForce
    }

    public func globalDOF(node: Int, axis: Int) -> Int {
        node * mesh.dofsPerNode + axis
    }

    public func elementDOFs(_ elementIndex: Int) -> [Int] {
        let element = mesh.elements[elementIndex]
        return element.nodes.flatMap { node in
            (0..<mesh.dofsPerNode).map { node * mesh.dofsPerNode + $0 }
        }
    }
}

public struct AnalysisOptions: Sendable {
    public var solverMethod: SparseSolverMethod
    public var computeReactions: Bool

    public init(
        solverMethod: SparseSolverMethod = .automatic,
        computeReactions: Bool = true
    ) {
        self.solverMethod = solverMethod
        self.computeReactions = computeReactions
    }
}

public struct ElementStress: Sendable {
    public let elementIndex: Int
    /// `[σxx, σyy, σzz, τxy, τyz, τzx]`.
    public let components: [Double]
    public let vonMises: Double
    public let measure: Double
}

public struct StaticResult: Sendable {
    public let displacements: [SIMD3<Double>]
    public let elementStresses: [ElementStress]
    public let nodalVonMises: [Double]
    public let reactions: [SIMD3<Double>]
    public let strainEnergy: Double
    public let solveReport: SparseSolveReport
    public let maxDisplacement: Double
    public let maxVonMises: Double
}

/// Linear static analysis with exact prescribed-value elimination.
public struct StaticAnalysis: Sendable {
    public var options: AnalysisOptions

    public init(options: AnalysisOptions = AnalysisOptions()) {
        self.options = options
    }

    public func solve(_ model: FEMModel) throws -> StaticResult {
        let mesh = model.mesh
        let dimension = mesh.dimension
        guard !model.constraints.isEmpty else {
            throw FEMError.invalidModel("At least one Dirichlet constraint is required")
        }

        let prescribed = try makePrescribedMap(
            model.constraints,
            nodeCount: mesh.nodes.count,
            dimension: dimension
        )
        try validateConstraintCoverage(
            mesh: mesh,
            prescribed: prescribed,
            dimension: dimension
        )

        var rightHandSide = [Double](repeating: 0, count: mesh.dofCount)
        try applyLoads(model, dimension: dimension, into: &rightHandSide)

        var triplets: [SparseTriplet] = []
        triplets.reserveCapacity(mesh.elements.count * 64)

        var kinematics: [ElementKinematics] = []
        kinematics.reserveCapacity(mesh.elements.count)

        for elementIndex in mesh.elements.indices {
            let data = try ElementKinematics.compute(
                mesh: mesh,
                material: model.material,
                elementIndex: elementIndex
            )
            kinematics.append(data)

            if model.bodyForce != .zero, model.material.density > 0 {
                let element = mesh.elements[elementIndex]
                let nodeForce = model.material.density * data.measure / Double(element.nodes.count)
                for node in element.nodes {
                    for axis in 0..<dimension {
                        rightHandSide[node * dimension + axis] += nodeForce * model.bodyForce[axis]
                    }
                }
            }

            let stiffness = data.stiffness()
            let localDOFs = model.elementDOFs(elementIndex)
            let size = data.dofCount
            for row in 0..<size {
                for column in 0...row {
                    let value = stiffness[row * size + column]
                    guard value != 0 else { continue }
                    triplets.append(SparseTriplet(
                        row: localDOFs[row],
                        column: localDOFs[column],
                        value: value
                    ))
                }
            }
        }

        let stiffness = try SparseMatrix.symmetric(
            size: mesh.dofCount,
            lowerTriplets: triplets
        )

        let freeDOFs = (0..<mesh.dofCount).filter { prescribed[$0] == nil }
        guard !freeDOFs.isEmpty else {
            throw FEMError.noFreeDegreesOfFreedom
        }

        let unsupported = freeDOFs.filter {
            let diagonal = stiffness.value(atRow: $0, column: $0)
            return !(diagonal.isFinite && diagonal > 0)
        }
        guard unsupported.isEmpty else {
            throw FEMError.unconstrainedDegreesOfFreedom(unsupported)
        }

        let reduction = try reduce(
            stiffness: stiffness,
            triplets: triplets,
            rightHandSide: rightHandSide,
            freeDOFs: freeDOFs,
            prescribed: prescribed
        )

        let solver: SparseSolver
        do {
            solver = try SparseSolver(
                matrix: reduction.matrix,
                method: options.solverMethod
            )
        } catch let error as SparseSolverError {
            throw FEMError.solver(error)
        } catch {
            throw FEMError.solverFailure(String(describing: error))
        }

        let report: SparseSolveReport
        do {
            report = try solver.solveWithReport(reduction.rightHandSide)
        } catch let error as SparseSolverError {
            throw FEMError.solver(error)
        } catch {
            throw FEMError.solverFailure(String(describing: error))
        }
        guard report.solution.allSatisfy(\.isFinite) else {
            throw FEMError.nonFiniteSolution
        }

        var globalSolution = [Double](repeating: 0, count: mesh.dofCount)
        for (dof, value) in prescribed {
            globalSolution[dof] = value
        }
        for (index, dof) in freeDOFs.enumerated() {
            globalSolution[dof] = report.solution[index]
        }

        let product = stiffness.multiply(globalSolution)
        let residual = zip(product, rightHandSide).map(-)

        let residualScale = max(
            VectorMath.norm(rightHandSide),
            VectorMath.norm(product),
            1e-30
        )
        let maximumFreeResidual = freeDOFs.reduce(0.0) { partial, dof in
            max(partial, abs(residual[dof]))
        }
        if maximumFreeResidual > 1e-6 * residualScale {
            throw FEMError.solverFailure(
                "Free residual \(maximumFreeResidual) exceeds the equilibrium tolerance"
            )
        }
        if let relativeResidual = report.relativeResidual, relativeResidual > 1e-5 {
            throw FEMError.solverFailure(
                "Solver reported relative residual \(relativeResidual)"
            )
        }

        var reactions = [SIMD3<Double>](repeating: .zero, count: mesh.nodes.count)
        if options.computeReactions {
            for node in mesh.nodes.indices {
                let base = node * dimension
                var vector = SIMD3<Double>.zero
                vector.x = residual[base]
                if dimension > 1 { vector.y = residual[base + 1] }
                if dimension > 2 { vector.z = residual[base + 2] }
                reactions[node] = vector
            }
        }

        var displacements = [SIMD3<Double>](repeating: .zero, count: mesh.nodes.count)
        var maxDisplacement = 0.0
        for node in mesh.nodes.indices {
            let base = node * dimension
            var vector = SIMD3<Double>.zero
            vector.x = globalSolution[base]
            if dimension > 1 { vector.y = globalSolution[base + 1] }
            if dimension > 2 { vector.z = globalSolution[base + 2] }
            displacements[node] = vector
            maxDisplacement = max(maxDisplacement, simd_length(vector))
        }

        var vonMisesSum = [Double](repeating: 0, count: mesh.nodes.count)
        var vonMisesCount = [Int](repeating: 0, count: mesh.nodes.count)
        var elementStresses: [ElementStress] = []
        elementStresses.reserveCapacity(mesh.elements.count)
        var maxVonMises = 0.0

        for data in kinematics {
            let localDOFs = model.elementDOFs(data.elementIndex)
            let localDisplacement = localDOFs.map { globalSolution[$0] }
            let stress = data.stress(localDisplacement: localDisplacement)
            let vonMises = ElementKinematics.vonMises(stress: stress)
            maxVonMises = max(maxVonMises, vonMises)
            elementStresses.append(ElementStress(
                elementIndex: data.elementIndex,
                components: stress,
                vonMises: vonMises,
                measure: data.measure
            ))
            for node in mesh.elements[data.elementIndex].nodes {
                vonMisesSum[node] += vonMises
                vonMisesCount[node] += 1
            }
        }

        let nodalVonMises = (0..<mesh.nodes.count).map { node in
            vonMisesCount[node] > 0 ? vonMisesSum[node] / Double(vonMisesCount[node]) : 0
        }

        let strainEnergy = 0.5 * VectorMath.dot(globalSolution, product)

        return StaticResult(
            displacements: displacements,
            elementStresses: elementStresses,
            nodalVonMises: nodalVonMises,
            reactions: reactions,
            strainEnergy: strainEnergy,
            solveReport: report,
            maxDisplacement: maxDisplacement,
            maxVonMises: maxVonMises
        )
    }

    private func makePrescribedMap(
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
                    throw FEMError.invalidConstraint(dof: condition.node * dimension + axis)
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

    private func applyLoads(
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
                    throw FEMError.invalidLoad("A two-dimensional model cannot carry an out-of-plane nodal load")
                }
                for axis in 0..<dimension {
                    rightHandSide[node * dimension + axis] += vector[axis]
                }

            case .traction(let nodes, let vector):
                guard dimension == 3 else {
                    throw FEMError.invalidLoad("Traction loads require a three-dimensional model")
                }
                guard nodes.count == 3, Set(nodes).count == 3,
                      nodes.allSatisfy({ (0..<model.mesh.nodes.count).contains($0) }) else {
                    throw FEMError.invalidLoad("A traction face needs three distinct valid nodes")
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

    private func validateConstraintCoverage(
        mesh: Mesh,
        prescribed: [Int: Double],
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
        for dof in prescribed.keys {
            constrainedComponents.insert(find(dof / dimension))
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

    private func reduce(
        stiffness: SparseMatrix,
        triplets: [SparseTriplet],
        rightHandSide: [Double],
        freeDOFs: [Int],
        prescribed: [Int: Double]
    ) throws -> (matrix: SparseMatrix, rightHandSide: [Double]) {
        var reducedIndex = [Int](repeating: -1, count: stiffness.rowCount)
        for (index, dof) in freeDOFs.enumerated() {
            reducedIndex[dof] = index
        }

        var reducedRHS = freeDOFs.map { rightHandSide[$0] }
        var reducedTriplets: [SparseTriplet] = []
        reducedTriplets.reserveCapacity(triplets.count)

        for triplet in triplets {
            let reducedRow = reducedIndex[triplet.row]
            let reducedColumn = reducedIndex[triplet.column]

            if reducedRow >= 0, reducedColumn >= 0 {
                reducedTriplets.append(SparseTriplet(
                    row: reducedRow,
                    column: reducedColumn,
                    value: triplet.value
                ))
            } else if reducedRow >= 0, let value = prescribed[triplet.column] {
                reducedRHS[reducedRow] -= triplet.value * value
            } else if reducedColumn >= 0, let value = prescribed[triplet.row] {
                reducedRHS[reducedColumn] -= triplet.value * value
            }
        }

        let matrix = try SparseMatrix.symmetric(
            size: freeDOFs.count,
            lowerTriplets: reducedTriplets
        )
        return (matrix, reducedRHS)
    }
}
