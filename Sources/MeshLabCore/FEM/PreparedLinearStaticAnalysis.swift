import Foundation
import simd

/// An assembled linear-static system whose stiffness factorization is reused
/// for multiple load vectors.
///
/// Geometry, materials, constraints, temperature field, and stiffness scales
/// are fixed at preparation time. Loads and body force may vary between solves.
/// This is the production load-case and multiple-right-hand-side seam.
public final class PreparedLinearStaticAnalysis {
    public let preparationCount = 1
    public private(set) var solveCount = 0

    private let baseModel: FEMModel
    private let options: AnalysisOptions
    private let stiffness: SparseMatrix
    private let kinematics: [ElementKinematics]
    private let thermalStrains: [[Double]]
    private let thermalLoads: [Double]
    private let prescribed: [Int: Double]
    private let freeDOFs: [Int]
    private let solver: SparseSolver

    public init(model: FEMModel, options: AnalysisOptions = AnalysisOptions()) throws {
        guard options.matrixFreeOptions == nil else {
            throw FEMError.invalidModel(
                "Prepared linear systems require an assembled solver"
            )
        }
        guard !model.constraints.isEmpty else {
            throw FEMError.invalidModel("At least one Dirichlet constraint is required")
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
        let freeDOFs = try FEMAssembly.freeDOFs(
            count: model.mesh.dofCount,
            prescribed: prescribed
        )
        let assembled = try FEMAssembly.assembleStiffness(model)
        let reduced = try FEMAssembly.reduced(assembled.matrix, freeDOFs: freeDOFs)
        let thermal = try FEMAssembly.thermalLoads(model, kinematics: assembled.kinematics)

        do {
            self.solver = try SparseSolver(
                matrix: reduced,
                method: options.solverMethod,
                directSettings: options.directSettings
            )
        } catch let error as SparseSolverError {
            throw FEMError.solver(error)
        } catch {
            throw FEMError.solverFailure(String(describing: error))
        }
        self.baseModel = model
        self.options = options
        self.stiffness = assembled.matrix
        self.kinematics = assembled.kinematics
        self.thermalStrains = thermal.strains
        self.thermalLoads = thermal.loads
        self.prescribed = prescribed
        self.freeDOFs = freeDOFs
    }

    public func solve(
        loads: [Load],
        bodyForce: SIMD3<Double> = .zero
    ) throws -> StaticResult {
        try Task.checkCancellation()
        var model = baseModel
        model.loads = loads
        model.bodyForce = bodyForce
        var rightHandSide = try FEMAssembly.loadVector(model)
        for index in rightHandSide.indices {
            rightHandSide[index] += thermalLoads[index]
        }
        let reducedRightHandSide = FEMAssembly.reducedLoads(
            matrix: stiffness,
            rightHandSide: rightHandSide,
            freeDOFs: freeDOFs,
            prescribed: prescribed
        )
        let report: SparseSolveReport
        do {
            report = try solver.solveWithReport(reducedRightHandSide)
        } catch let error as SparseSolverError {
            throw FEMError.solver(error)
        } catch {
            throw FEMError.solverFailure(String(describing: error))
        }
        guard report.solution.allSatisfy(\.isFinite) else {
            throw FEMError.nonFiniteSolution
        }
        let result = try makeResult(
            model: model,
            rightHandSide: rightHandSide,
            report: report
        )
        solveCount += 1
        return result
    }

    public func solve(
        rightHandSides: [(loads: [Load], bodyForce: SIMD3<Double>)]
    ) throws -> [StaticResult] {
        try rightHandSides.map { try solve(loads: $0.loads, bodyForce: $0.bodyForce) }
    }

    private func makeResult(
        model: FEMModel,
        rightHandSide: [Double],
        report: SparseSolveReport
    ) throws -> StaticResult {
        let mesh = model.mesh
        let dimension = mesh.dimension
        var globalSolution = [Double](repeating: 0, count: mesh.dofCount)
        for (dof, value) in prescribed { globalSolution[dof] = value }
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
        let maximumFreeResidual = freeDOFs.reduce(0.0) {
            max($0, abs(residual[$1]))
        }
        guard maximumFreeResidual <= 1e-6 * residualScale else {
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
        var equilibriumReactions = reactions
        for node in mesh.nodes.indices {
            let base = node * dimension
            var vector = SIMD3<Double>.zero
            for axis in 0..<dimension where prescribed[base + axis] != nil {
                vector[axis] = residual[base + axis]
            }
            equilibriumReactions[node] = vector
            if options.computeReactions { reactions[node] = vector }
        }

        var displacements = [SIMD3<Double>](repeating: .zero, count: mesh.nodes.count)
        var maximumDisplacement = 0.0
        for node in mesh.nodes.indices {
            let base = node * dimension
            var vector = SIMD3<Double>.zero
            vector.x = globalSolution[base]
            if dimension > 1 { vector.y = globalSolution[base + 1] }
            if dimension > 2 { vector.z = globalSolution[base + 2] }
            displacements[node] = vector
            maximumDisplacement = max(maximumDisplacement, simd_length(vector))
        }

        var stressSum = [Double](repeating: 0, count: mesh.nodes.count)
        var stressCount = [Int](repeating: 0, count: mesh.nodes.count)
        var elementStresses: [ElementStress] = []
        var maximumStress = 0.0
        var strainEnergy = 0.0
        elementStresses.reserveCapacity(kinematics.count)
        for (index, data) in kinematics.enumerated() {
            let local = model.elementDOFs(data.elementIndex).map { globalSolution[$0] }
            let stress = data.stress(
                localDisplacement: local,
                initialStrain: thermalStrains[index]
            )
            strainEnergy += data.strainEnergy(
                localDisplacement: local,
                initialStrain: thermalStrains[index]
            ) * (try model.stiffnessScale(forElement: data.elementIndex))
            let vonMises = ElementKinematics.vonMises(stress: stress)
            maximumStress = max(maximumStress, vonMises)
            elementStresses.append(ElementStress(
                elementIndex: data.elementIndex,
                components: stress,
                vonMises: vonMises,
                measure: data.measure
            ))
            for node in mesh.elements[data.elementIndex].nodes {
                stressSum[node] += vonMises
                stressCount[node] += 1
            }
        }
        let nodalStress = mesh.nodes.indices.map {
            stressCount[$0] == 0 ? 0 : stressSum[$0] / Double(stressCount[$0])
        }

        var appliedForce = SIMD3<Double>.zero
        var reactionForce = SIMD3<Double>.zero
        var appliedMoment = SIMD3<Double>.zero
        var reactionMoment = SIMD3<Double>.zero
        for node in mesh.nodes.indices {
            let base = node * dimension
            var applied = SIMD3<Double>.zero
            applied.x = rightHandSide[base]
            if dimension > 1 { applied.y = rightHandSide[base + 1] }
            if dimension > 2 { applied.z = rightHandSide[base + 2] }
            appliedForce += applied
            reactionForce += equilibriumReactions[node]
            appliedMoment += simd_cross(mesh.nodes[node], applied)
            reactionMoment += simd_cross(mesh.nodes[node], equilibriumReactions[node])
        }
        let equilibrium = StaticEquilibriumReport(
            appliedForce: appliedForce,
            reactionForce: reactionForce,
            forceImbalance: appliedForce + reactionForce,
            appliedMoment: appliedMoment,
            reactionMoment: reactionMoment,
            momentImbalance: appliedMoment + reactionMoment,
            maximumFreeResidual: maximumFreeResidual,
            relativeFreeResidual: maximumFreeResidual / residualScale
        )
        return StaticResult(
            displacements: displacements,
            elementStresses: elementStresses,
            nodalVonMises: nodalStress,
            reactions: reactions,
            strainEnergy: strainEnergy,
            solveReport: report,
            maxDisplacement: maximumDisplacement,
            maxVonMises: maximumStress,
            equilibrium: equilibrium
        )
    }
}
