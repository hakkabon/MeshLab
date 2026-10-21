import Foundation
import simd

public struct DirichletCondition: Sendable, Hashable, Codable {
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

public enum Load: Sendable, Hashable, Codable {
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
    /// Per-node temperature change relative to the stress-free reference
    /// temperature. When non-empty, the static solve adds the equivalent
    /// thermal load and subtracts the free thermal strain during stress
    /// recovery. Thermal stress coupling currently requires a 3D mesh.
    public var temperatureChange: [Double]
    /// Optional per-element stiffness multipliers. Empty means every element
    /// uses its full material stiffness. Topology optimization supplies
    /// SIMP-scaled values here; mass and thermal properties are unchanged.
    public var elementStiffnessScales: [Double]

    public init(
        mesh: Mesh,
        material: ElasticMaterial,
        constraints: [DirichletCondition],
        loads: [Load] = [],
        bodyForce: SIMD3<Double> = .zero,
        temperatureChange: [Double] = [],
        elementStiffnessScales: [Double] = []
    ) {
        self.mesh = mesh
        self.material = material
        self.constraints = constraints
        self.loads = loads
        self.bodyForce = bodyForce
        self.temperatureChange = temperatureChange
        self.elementStiffnessScales = elementStiffnessScales
    }

    public func stiffnessScale(forElement index: Int) throws -> Double {
        guard mesh.elements.indices.contains(index) else {
            throw FEMError.invalidModel("Element stiffness scale index is out of range")
        }
        guard !elementStiffnessScales.isEmpty else { return 1 }
        guard elementStiffnessScales.count == mesh.elements.count else {
            throw FEMError.invalidModel(
                "Element stiffness scales must provide one value per element"
            )
        }
        let scale = elementStiffnessScales[index]
        guard scale.isFinite, scale >= 0 else {
            throw FEMError.invalidModel(
                "Element stiffness scales must be finite and non-negative"
            )
        }
        return scale
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

public struct MatrixFreeOptions: Sendable, Hashable, Codable {
    public var maximumIterations: Int
    public var relativeTolerance: Double
    public var useJacobiPreconditioner: Bool

    public init(
        maximumIterations: Int = 1_000,
        relativeTolerance: Double = 1e-8,
        useJacobiPreconditioner: Bool = true
    ) {
        self.maximumIterations = maximumIterations
        self.relativeTolerance = relativeTolerance
        self.useJacobiPreconditioner = useJacobiPreconditioner
    }
}

public struct AnalysisOptions: Sendable {
    public var solverMethod: SparseSolverMethod
    /// Ordering and refinement options used by NumericCore direct solvers.
    public var directSettings: SparseDirectSettings
    public var computeReactions: Bool
    /// When present, static analysis uses an element-by-element matrix-free
    /// conjugate-gradient solve instead of assembling a global sparse matrix.
    public var matrixFreeOptions: MatrixFreeOptions?

    public init(
        solverMethod: SparseSolverMethod = .automatic,
        directSettings: SparseDirectSettings = SparseDirectSettings(),
        computeReactions: Bool = true,
        matrixFreeOptions: MatrixFreeOptions? = nil
    ) {
        self.solverMethod = solverMethod
        self.directSettings = directSettings
        self.computeReactions = computeReactions
        self.matrixFreeOptions = matrixFreeOptions
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

        let prescribed = try FEMAssembly.prescribedMap(
            model.constraints,
            nodeCount: mesh.nodes.count,
            dimension: dimension
        )
        try FEMAssembly.validateConstraintCoverage(
            mesh: mesh,
            prescribed: prescribed,
            dimension: dimension
        )

        let externalLoads = try FEMAssembly.loadVector(model)

        let matrixFree = options.matrixFreeOptions
        var triplets: [SparseTriplet] = []
        if matrixFree == nil {
            triplets.reserveCapacity(mesh.elements.count * 64)
        }
        var elementOperators: [ElementStiffnessOperator.Element] = []
        if matrixFree != nil {
            elementOperators.reserveCapacity(mesh.elements.count)
        }
        var diagonal = [Double](repeating: 0, count: mesh.dofCount)

        var kinematics: [ElementKinematics] = []
        kinematics.reserveCapacity(mesh.elements.count)

        for elementIndex in mesh.elements.indices {
            try Task.checkCancellation()
            let data = try ElementKinematics.compute(
                mesh: mesh,
                material: model.material,
                elementIndex: elementIndex
            )
            kinematics.append(data)

            let stiffness = data.stiffness()
            let scale = try model.stiffnessScale(forElement: elementIndex)
            let localDOFs = model.elementDOFs(elementIndex)
            let size = data.dofCount
            for row in 0..<size {
                diagonal[localDOFs[row]] += stiffness[row * size + row] * scale
                guard matrixFree == nil else { continue }
                for column in 0...row {
                    let value = stiffness[row * size + column] * scale
                    guard value != 0 else { continue }
                    triplets.append(SparseTriplet(
                        row: localDOFs[row],
                        column: localDOFs[column],
                        value: value
                    ))
                }
            }
            if matrixFree != nil {
                elementOperators.append(ElementStiffnessOperator.Element(
                    dofs: localDOFs,
                    size: size,
                    stiffness: stiffness.map { $0 * scale }
                ))
            }
        }

        let thermal = try FEMAssembly.thermalLoads(
            model,
            kinematics: kinematics
        )
        var rightHandSide = externalLoads
        for dof in rightHandSide.indices {
            rightHandSide[dof] += thermal.loads[dof]
        }

        let freeDOFs = try FEMAssembly.freeDOFs(
            count: mesh.dofCount,
            prescribed: prescribed
        )

        let unsupported = freeDOFs.filter {
            let value = diagonal[$0]
            return !(value.isFinite && value > 0)
        }
        guard unsupported.isEmpty else {
            throw FEMError.unconstrainedDegreesOfFreedom(unsupported)
        }

        let matrixFreeOperator: ElementStiffnessOperator?
        var assembledStiffness: SparseMatrix?
        let report: SparseSolveReport
        if let matrixFree {
            let op = ElementStiffnessOperator(
                dofCount: mesh.dofCount,
                elements: elementOperators,
                diagonal: diagonal
            )
            matrixFreeOperator = op
            var prescribedVector = [Double](repeating: 0, count: mesh.dofCount)
            for (dof, value) in prescribed {
                prescribedVector[dof] = value
            }
            let prescribedProduct = op.multiply(prescribedVector)
            let reducedRightHandSide = freeDOFs.map {
                rightHandSide[$0] - prescribedProduct[$0]
            }
            let solved = try MatrixFreeConjugateGradient.solve(
                operator: op,
                freeDOFs: freeDOFs,
                rightHandSide: reducedRightHandSide,
                options: matrixFree
            )
            report = SparseSolveReport(
                solution: solved.solution,
                method: .conjugateGradient(SparseIterativeSettings(
                    maxIterations: matrixFree.maximumIterations,
                    tolerance: matrixFree.relativeTolerance,
                    preconditioner: matrixFree.useJacobiPreconditioner
                        ? .jacobi
                        : .none
                )),
                iterations: solved.iterations,
                relativeResidual: solved.relativeResidual,
                factorNonZeroCount: nil,
                converged: true,
                backwardError: nil,
                refinementSteps: nil,
                inertia: nil
            )
        } else {
            matrixFreeOperator = nil
            let stiffness = try SparseMatrix.symmetric(
                size: mesh.dofCount,
                lowerTriplets: triplets
            )
            assembledStiffness = stiffness
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
                    method: options.solverMethod,
                    directSettings: options.directSettings
                )
            } catch let error as SparseSolverError {
                throw FEMError.solver(error)
            } catch {
                throw FEMError.solverFailure(String(describing: error))
            }

            do {
                report = try solver.solveWithReport(reduction.rightHandSide)
            } catch let error as SparseSolverError {
                throw FEMError.solver(error)
            } catch {
                throw FEMError.solverFailure(String(describing: error))
            }
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

        let product: [Double]
        if let matrixFreeOperator {
            product = matrixFreeOperator.multiply(globalSolution)
        } else if let assembledStiffness {
            product = assembledStiffness.multiply(globalSolution)
        } else {
            throw FEMError.solverFailure("Static solve produced no stiffness operator")
        }
        let residual = zip(product, rightHandSide).map(-)

        let residualScale = max(
            VectorMath.norm(rightHandSide),
            VectorMath.norm(product),
            1e-30
        )
        let maximumFreeResidual = freeDOFs.reduce(0.0) { partial, dof in
            max(partial, abs(residual[dof]))
        }
        let equilibriumTolerance = matrixFree.map {
            max($0.relativeTolerance * 10, 1e-6)
        } ?? 1e-6
        if maximumFreeResidual > equilibriumTolerance * residualScale {
            throw FEMError.solverFailure(
                "Free residual \(maximumFreeResidual) exceeds the equilibrium tolerance"
            )
        }
        let reportTolerance = matrixFree.map {
            max($0.relativeTolerance * 10, 1e-5)
        } ?? 1e-5
        if let relativeResidual = report.relativeResidual,
           relativeResidual > reportTolerance {
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
        var strainEnergy = 0.0

        for (index, data) in kinematics.enumerated() {
            let localDOFs = model.elementDOFs(data.elementIndex)
            let localDisplacement = localDOFs.map { globalSolution[$0] }
            let stress = data.stress(
                localDisplacement: localDisplacement,
                initialStrain: thermal.strains[index]
            )
            strainEnergy += data.strainEnergy(
                localDisplacement: localDisplacement,
                initialStrain: thermal.strains[index]
            ) * (try model.stiffnessScale(forElement: data.elementIndex))
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
