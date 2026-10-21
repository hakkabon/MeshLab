import Foundation
import simd

public struct ModalOptions: Sendable, Hashable {
    /// Number of lowest flexible modes to compute.
    public var modeCount: Int

    public init(modeCount: Int = 6) {
        self.modeCount = modeCount
    }
}

public struct VibrationMode: Sendable {
    public let index: Int
    public let angularFrequency: Double
    public let frequencyHz: Double
    /// Full-DOF, mass-normalized mode shape. Constrained entries are zero.
    public let shape: [Double]
    public let relativeResidual: Double
    public let dimension: Int

    public var displacements: [SIMD3<Double>] {
        stride(from: 0, to: shape.count, by: dimension).map { base in
            switch dimension {
            case 2:
                return SIMD3<Double>(shape[base], shape[base + 1], 0)
            default:
                return SIMD3<Double>(
                    shape[base],
                    shape[base + 1],
                    shape[base + 2]
                )
            }
        }
    }
}

public struct ModalResult: Sendable {
    public let modes: [VibrationMode]
    public let maximumRelativeResidual: Double
    public let maximumMassOrthogonalityError: Double
    public let mass: SparseMatrix
    public let stiffness: SparseMatrix

    public var frequenciesHz: [Double] {
        modes.map(\.frequencyHz)
    }

    public var angularFrequencies: [Double] {
        modes.map(\.angularFrequency)
    }

    public var modeShapes: [[Double]] {
        modes.map(\.shape)
    }
}

/// Solves the constrained generalized eigenproblem `K φ = λ M φ`.
///
/// The reduced problem is dense and handled by LAPACK's symmetric generalized
/// eigensolver. This is intended for the current tet4/tri3 product meshes;
/// large-scale sparse modal analysis can replace the dense step behind this
/// API later.
public struct ModalAnalysis: Sendable {
    public var options: ModalOptions

    public init(options: ModalOptions = ModalOptions()) {
        self.options = options
    }

    public func solve(_ model: FEMModel) throws -> ModalResult {
        guard !model.constraints.isEmpty else {
            throw FEMError.invalidModel("At least one Dirichlet constraint is required")
        }
        guard options.modeCount > 0 else {
            throw FEMError.invalidModel("Mode count must be positive")
        }
        guard model.constraints.allSatisfy({ $0.value == 0 }) else {
            throw FEMError.invalidModel(
                "Modal analysis requires homogeneous Dirichlet constraints"
            )
        }

        let dimension = model.mesh.dimension
        let prescribed = try FEMAssembly.prescribedMap(
            model.constraints,
            nodeCount: model.mesh.nodes.count,
            dimension: dimension
        )
        try FEMAssembly.validateConstraintCoverage(
            mesh: model.mesh,
            prescribed: prescribed,
            dimension: dimension
        )
        let free = try FEMAssembly.freeDOFs(
            count: model.mesh.dofCount,
            prescribed: prescribed
        )
        guard options.modeCount <= free.count else {
            throw FEMError.invalidModel(
                "Mode count exceeds the number of free degrees of freedom"
            )
        }

        let assembled = try FEMAssembly.assembleStiffness(model)
        let mass = try FEMAssembly.assembleMass(
            model,
            kinematics: assembled.kinematics
        )
        let reducedStiffness = try FEMAssembly.reduced(
            assembled.matrix,
            freeDOFs: free
        )
        let reducedMass = try FEMAssembly.reduced(mass, freeDOFs: free)

        let denseStiffness = denseValues(reducedStiffness)
        let denseMass = denseValues(reducedMass)
        let eigen: (eigenvalues: [Double], eigenvectors: [[Double]])
        do {
            eigen = try SymmetricGeneralizedEigenSolver.solve(
                stiffness: denseStiffness,
                mass: denseMass,
                size: free.count
            )
        } catch {
            throw FEMError.solverFailure(
                "Modal eigensolver failed: \(error)"
            )
        }

        let maximumEigenvalue = eigen.eigenvalues.max() ?? 0
        let threshold = max(1e-12, maximumEigenvalue * 1e-12)
        let flexible = eigen.eigenvalues.indices.filter {
            eigen.eigenvalues[$0] > threshold
        }
        guard flexible.count >= options.modeCount else {
            throw FEMError.invalidModel(
                "The constrained structure contains a rigid-body mechanism"
            )
        }

        var modes: [VibrationMode] = []
        modes.reserveCapacity(options.modeCount)
        var maximumResidual = 0.0
        let dofCount = model.mesh.dofCount

        for (order, eigenIndex) in flexible.prefix(options.modeCount).enumerated() {
            let lambda = eigen.eigenvalues[eigenIndex]
            var shape = [Double](repeating: 0, count: dofCount)
            for (local, dof) in free.enumerated() {
                shape[dof] = eigen.eigenvectors[eigenIndex][local]
            }

            let kShape = assembled.matrix.multiply(shape)
            let mShape = mass.multiply(shape)
            var residualSquared = 0.0
            var kNormSquared = 0.0
            for dof in free {
                let residual = kShape[dof] - lambda * mShape[dof]
                residualSquared += residual * residual
                kNormSquared += kShape[dof] * kShape[dof]
            }
            let residual = sqrt(residualSquared) / max(1, sqrt(kNormSquared))
            maximumResidual = max(maximumResidual, residual)
            let omega = sqrt(max(0, lambda))
            modes.append(VibrationMode(
                index: order,
                angularFrequency: omega,
                frequencyHz: omega / (2 * .pi),
                shape: shape,
                relativeResidual: residual,
                dimension: dimension
            ))
        }

        var orthogonalityError = 0.0
        for first in modes.indices {
            let firstMass = mass.multiply(modes[first].shape)
            for second in modes.indices {
                let product = zip(modes[second].shape, firstMass)
                    .reduce(0.0) { $0 + $1.0 * $1.1 }
                orthogonalityError = max(
                    orthogonalityError,
                    abs(product - (first == second ? 1 : 0))
                )
            }
        }

        return ModalResult(
            modes: modes,
            maximumRelativeResidual: maximumResidual,
            maximumMassOrthogonalityError: orthogonalityError,
            mass: mass,
            stiffness: assembled.matrix
        )
    }

    private func denseValues(_ matrix: SparseMatrix) -> [Double] {
        let dense = matrix.toDense()
        var values = [Double](repeating: 0, count: dense.rows * dense.columns)
        for row in 0..<dense.rows {
            for column in 0..<dense.columns {
                values[row * dense.columns + column] = dense[row, column]
            }
        }
        return values
    }
}

public struct TransientOptions: Sendable, Hashable {
    public var timeStep: Double
    public var steps: Int
    /// Rayleigh coefficient in `C = massDamping * M + stiffnessDamping * K`.
    public var massDamping: Double
    /// Rayleigh coefficient in `C = massDamping * M + stiffnessDamping * K`.
    public var stiffnessDamping: Double
    public var solverMethod: SparseSolverMethod
    public var directSettings: SparseDirectSettings

    public init(
        timeStep: Double,
        steps: Int,
        massDamping: Double = 0,
        stiffnessDamping: Double = 0,
        solverMethod: SparseSolverMethod = .automatic,
        directSettings: SparseDirectSettings = SparseDirectSettings()
    ) {
        self.timeStep = timeStep
        self.steps = steps
        self.massDamping = massDamping
        self.stiffnessDamping = stiffnessDamping
        self.solverMethod = solverMethod
        self.directSettings = directSettings
    }
}

public struct TransientState: Sendable {
    public let time: Double
    public let displacement: [SIMD3<Double>]
    public let velocity: [SIMD3<Double>]
    public let acceleration: [SIMD3<Double>]
    public let kineticEnergy: Double
    public let strainEnergy: Double
}

public struct TransientResult: Sendable {
    public let states: [TransientState]
    public let maximumRelativeEquilibriumResidual: Double
    public let mass: SparseMatrix
    public let stiffness: SparseMatrix
}

/// Average-acceleration Newmark integration for `M u'' + C u' + K u = f(t)`.
///
/// Constraints must be homogeneous. `loadHistory` contains one load set for
/// times zero through `options.steps`, inclusive.
public struct TransientAnalysis: Sendable {
    public var options: TransientOptions

    public init(options: TransientOptions) {
        self.options = options
    }

    public func solve(
        _ model: FEMModel,
        loadHistory: [[Load]],
        initialDisplacement: [SIMD3<Double>] = [],
        initialVelocity: [SIMD3<Double>] = []
    ) throws -> TransientResult {
        guard options.timeStep.isFinite, options.timeStep > 0,
              options.steps > 0,
              options.massDamping.isFinite, options.massDamping >= 0,
              options.stiffnessDamping.isFinite, options.stiffnessDamping >= 0 else {
            throw FEMError.invalidModel("Invalid transient analysis options")
        }
        guard loadHistory.count == options.steps + 1 else {
            throw FEMError.invalidModel(
                "Load history must contain steps + 1 entries"
            )
        }
        guard !model.constraints.isEmpty else {
            throw FEMError.invalidModel("At least one Dirichlet constraint is required")
        }
        guard model.constraints.allSatisfy({ $0.value == 0 }) else {
            throw FEMError.invalidModel(
                "Transient analysis requires homogeneous Dirichlet constraints"
            )
        }

        let dimension = model.mesh.dimension
        let prescribed = try FEMAssembly.prescribedMap(
            model.constraints,
            nodeCount: model.mesh.nodes.count,
            dimension: dimension
        )
        try FEMAssembly.validateConstraintCoverage(
            mesh: model.mesh,
            prescribed: prescribed,
            dimension: dimension
        )
        let free = try FEMAssembly.freeDOFs(
            count: model.mesh.dofCount,
            prescribed: prescribed
        )

        let assembled = try FEMAssembly.assembleStiffness(model)
        let mass = try FEMAssembly.assembleMass(
            model,
            kinematics: assembled.kinematics
        )
        let reducedStiffness = try FEMAssembly.reduced(
            assembled.matrix,
            freeDOFs: free
        )
        let reducedMass = try FEMAssembly.reduced(mass, freeDOFs: free)

        let initialU = try fullVector(
            initialDisplacement,
            nodeCount: model.mesh.nodes.count,
            dimension: dimension,
            name: "initial displacement"
        )
        let initialV = try fullVector(
            initialVelocity,
            nodeCount: model.mesh.nodes.count,
            dimension: dimension,
            name: "initial velocity"
        )
        for dof in prescribed.keys {
            guard abs(initialU[dof]) <= 1e-15, abs(initialV[dof]) <= 1e-15 else {
                throw FEMError.invalidModel(
                    "Constrained initial displacement and velocity must be zero"
                )
            }
        }

        var forces: [[Double]] = []
        forces.reserveCapacity(loadHistory.count)
        for loads in loadHistory {
            var loadModel = model
            loadModel.loads = loads
            let full = try FEMAssembly.loadVector(loadModel)
            forces.append(FEMAssembly.reduced(full, freeDOFs: free))
        }

        let alpha = options.massDamping
        let beta = options.stiffnessDamping
        let dt = options.timeStep
        let a0 = 4 / (dt * dt)
        let a1 = 2 / dt

        let massSolver = try makeSolver(reducedMass)
        let effective = try combine(
            reducedStiffness,
            stiffnessFactor: 1 + a1 * beta,
            reducedMass,
            massFactor: a0 + a1 * alpha
        )
        let effectiveSolver = try makeSolver(effective)

        var u = FEMAssembly.reduced(initialU, freeDOFs: free)
        var v = FEMAssembly.reduced(initialV, freeDOFs: free)
        var initialRHS = forces[0]
        subtract(&initialRHS, scale(reducedMass.multiply(v), alpha))
        subtract(&initialRHS, scale(reducedStiffness.multiply(v), beta))
        subtract(&initialRHS, reducedStiffness.multiply(u))
        var acceleration = try solve(massSolver, initialRHS)

        var states: [TransientState] = []
        states.reserveCapacity(options.steps + 1)
        var maximumResidual = 0.0
        states.append(makeState(
            time: 0,
            u: u,
            v: v,
            a: acceleration,
            mass: reducedMass,
            stiffness: reducedStiffness,
            free: free,
            nodeCount: model.mesh.nodes.count,
            dimension: dimension
        ))

        for step in 1...options.steps {
            var rhs = forces[step]
            let predictor = zip(zip(u, v), acceleration).map { pair, a in
                a0 * pair.0 + 2 * a1 * pair.1 + a
            }
            add(&rhs, scale(reducedMass.multiply(predictor), 1))
            let velocityPredictor = zip(u, v).map { displacement, velocity in
                a1 * displacement + velocity
            }
            add(&rhs, scale(reducedMass.multiply(velocityPredictor), alpha))
            add(&rhs, scale(reducedStiffness.multiply(velocityPredictor), beta))

            let nextU = try solve(effectiveSolver, rhs)
            let nextA = zip(zip(zip(nextU, u), v), acceleration).map { values, a in
                a0 * (values.0.0 - values.0.1) - 2 * a1 * values.1 - a
            }
            var nextV = [Double](repeating: 0, count: v.count)
            for index in v.indices {
                nextV[index] = v[index] + 0.5 * dt * (acceleration[index] + nextA[index])
            }

            var residual = reducedMass.multiply(nextA)
            add(&residual, scale(reducedMass.multiply(nextV), alpha))
            add(&residual, scale(reducedStiffness.multiply(nextV), beta))
            add(&residual, reducedStiffness.multiply(nextU))
            subtract(&residual, forces[step])
            let residualNorm = sqrt(residual.reduce(0) { $0 + $1 * $1 })
            let forceNorm = sqrt(forces[step].reduce(0) { $0 + $1 * $1 })
            maximumResidual = max(maximumResidual, residualNorm / max(1, forceNorm))

            u = nextU
            v = nextV
            acceleration = nextA
            states.append(makeState(
                time: Double(step) * dt,
                u: u,
                v: v,
                a: acceleration,
                mass: reducedMass,
                stiffness: reducedStiffness,
                free: free,
                nodeCount: model.mesh.nodes.count,
                dimension: dimension
            ))
        }

        return TransientResult(
            states: states,
            maximumRelativeEquilibriumResidual: maximumResidual,
            mass: mass,
            stiffness: assembled.matrix
        )
    }

    private func makeSolver(_ matrix: SparseMatrix) throws -> SparseSolver {
        do {
            return try SparseSolver(
                matrix: matrix,
                method: options.solverMethod,
                directSettings: options.directSettings
            )
        } catch let error as SparseSolverError {
            throw FEMError.solver(error)
        } catch {
            throw FEMError.solverFailure(String(describing: error))
        }
    }

    private func solve(_ solver: SparseSolver, _ rhs: [Double]) throws -> [Double] {
        do {
            let solution = try solver.solve(rhs)
            guard solution.allSatisfy(\.isFinite) else {
                throw FEMError.nonFiniteSolution
            }
            return solution
        } catch let error as FEMError {
            throw error
        } catch let error as SparseSolverError {
            throw FEMError.solver(error)
        } catch {
            throw FEMError.solverFailure(String(describing: error))
        }
    }

    private func combine(
        _ stiffness: SparseMatrix,
        stiffnessFactor: Double,
        _ mass: SparseMatrix,
        massFactor: Double
    ) throws -> SparseMatrix {
        var triplets = stiffness.coordinateTriplets().map {
            SparseTriplet(
                row: $0.row,
                column: $0.column,
                value: $0.value * stiffnessFactor
            )
        }
        triplets.append(contentsOf: mass.coordinateTriplets().map {
            SparseTriplet(
                row: $0.row,
                column: $0.column,
                value: $0.value * massFactor
            )
        })
        return try SparseMatrix.symmetric(
            size: stiffness.rowCount,
            lowerTriplets: triplets
        )
    }

    private func makeState(
        time: Double,
        u: [Double],
        v: [Double],
        a: [Double],
        mass: SparseMatrix,
        stiffness: SparseMatrix,
        free: [Int],
        nodeCount: Int,
        dimension: Int
    ) -> TransientState {
        func reshape(_ values: [Double]) -> [SIMD3<Double>] {
            let full = FEMAssembly.full(
                values,
                freeDOFs: free,
                count: nodeCount * dimension
            )
            return (0..<nodeCount).map { node in
                let base = node * dimension
                switch dimension {
                case 2:
                    return SIMD3<Double>(full[base], full[base + 1], 0)
                default:
                    return SIMD3<Double>(
                        full[base],
                        full[base + 1],
                        full[base + 2]
                    )
                }
            }
        }
        let kinetic = 0.5 * VectorMath.dot(v, mass.multiply(v))
        let strain = 0.5 * VectorMath.dot(u, stiffness.multiply(u))
        return TransientState(
            time: time,
            displacement: reshape(u),
            velocity: reshape(v),
            acceleration: reshape(a),
            kineticEnergy: kinetic,
            strainEnergy: strain
        )
    }

    private func fullVector(
        _ values: [SIMD3<Double>],
        nodeCount: Int,
        dimension: Int,
        name: String
    ) throws -> [Double] {
        guard values.isEmpty || values.count == nodeCount else {
            throw FEMError.invalidModel(
                "\(name.capitalized) must contain one vector per node"
            )
        }
        guard values.allSatisfy({
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
        }) else {
            throw FEMError.invalidModel("\(name.capitalized) contains a non-finite value")
        }
        if dimension == 2, values.contains(where: { $0.z != 0 }) {
            throw FEMError.invalidModel(
                "\(name.capitalized) cannot have an out-of-plane component in 2D"
            )
        }
        var result = [Double](repeating: 0, count: nodeCount * dimension)
        for (node, value) in values.enumerated() {
            let base = node * dimension
            result[base] = value.x
            if dimension > 1 { result[base + 1] = value.y }
            if dimension > 2 { result[base + 2] = value.z }
        }
        return result
    }

    private func scale(_ vector: [Double], _ factor: Double) -> [Double] {
        vector.map { $0 * factor }
    }

    private func add(_ target: inout [Double], _ other: [Double]) {
        for index in target.indices {
            target[index] += other[index]
        }
    }

    private func subtract(_ target: inout [Double], _ other: [Double]) {
        for index in target.indices {
            target[index] -= other[index]
        }
    }
}
