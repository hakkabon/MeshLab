import Foundation
import MeshLabCore
import Testing
import simd

@Test func numericStackProvenanceIsExactStableAndDeterministic() throws {
    let first = NumericStackProvenance.current
    let second = NumericStackProvenance.current
    #expect(first == second)
    #expect(first.swiftNumericCoreVersion == "1.0.0")
    #expect(first.rustNumericCoreVersion == "0.34.0")
    #expect(first.compatibilityEpoch == 1)
    #expect(!first.capabilities.isEmpty)
    #expect(first.capabilities.contains { $0.identifier == "sparse-linear-algebra" })
    #expect(first.capabilityDigest.count == 16)
}

@Test func engineeringUnitsRoundTripPhysicalRequirements() {
    let units = EngineeringUnitSystem.millimeterMegapascal
    #expect(abs(units.length.solverValue(fromDisplay: 2.5) - 0.0025) < 1e-15)
    #expect(abs(units.length.displayValue(fromSolver: 0.0025) - 2.5) < 1e-15)
    #expect(units.stress.solverValue(fromDisplay: 250) == 250e6)
    #expect(units.stress.displayValue(fromSolver: 250e6) == 250)
    #expect(abs(units.temperature.solverValue(fromDisplay: 20) - 293.15) < 1e-12)
    #expect(abs(units.temperature.displayValue(fromSolver: 293.15) - 20) < 1e-12)
}

@Test func preparedLinearSystemMatchesIndependentSolvesAndReusesPreparation() throws {
    let project = try MeshLabProject.cantileverExample()
    let base = project.makeModel()
    let prepared = try PreparedLinearStaticAnalysis(
        model: FEMModel(
            mesh: base.mesh,
            material: base.material,
            constraints: base.constraints
        ),
        options: AnalysisOptions(solverMethod: .numericCoreCholesky)
    )
    let first = try prepared.solve(loads: base.loads, bodyForce: base.bodyForce)
    let doubledLoads = base.loads.map { $0.scaledForTesting(by: 2) }
    let second = try prepared.solve(loads: doubledLoads, bodyForce: base.bodyForce * 2)
    var independentModel = base
    independentModel.loads = doubledLoads
    independentModel.bodyForce *= 2
    let independent = try StaticAnalysis(options: AnalysisOptions(
        solverMethod: .numericCoreCholesky
    )).solve(independentModel)

    #expect(prepared.preparationCount == 1)
    #expect(prepared.solveCount == 2)
    #expect(abs(second.maxDisplacement / first.maxDisplacement - 2) < 1e-9)
    #expect(abs(second.maxDisplacement - independent.maxDisplacement) < 1e-14)
    #expect(abs(second.maxVonMises - independent.maxVonMises) < 1e-7)
}

@Test func publicElementKernelProducesConsistentTangentMassAndResidual() throws {
    let mesh = try Mesh(
        nodes: [
            SIMD3<Double>(0, 0, 0),
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, 1, 0),
            SIMD3<Double>(0, 0, 1),
        ],
        elements: [Element(type: .tetrahedron4, nodes: [0, 1, 2, 3])]
    )
    let material = try ElasticMaterial(
        youngModulus: 10e6,
        poissonRatio: 0.3,
        density: 2
    )
    let kernel: any FEMElementKernel = LinearContinuumElementKernel()
    let displacement = (0..<12).map { Double($0) * 1e-6 }
    let evaluation = try kernel.evaluate(FEMElementEvaluationRequest(
        mesh: mesh,
        elementIndex: 0,
        material: material,
        localDisplacement: displacement
    ))

    #expect(evaluation.degreesOfFreedom == Array(0..<12))
    #expect(evaluation.tangent.count == 144)
    #expect(evaluation.consistentMass.count == 144)
    #expect(evaluation.internalForce.count == 12)
    #expect(evaluation.stress.count == 6)
    #expect(evaluation.strainEnergy >= 0)
    for row in 0..<12 {
        let product = (0..<12).reduce(0.0) {
            $0 + evaluation.tangent[row * 12 + $1] * displacement[$1]
        }
        #expect(abs(product - evaluation.internalForce[row]) < 1e-10)
    }
}

@Test func projectTransientWorkflowExportsHistoryAndQualifies() throws {
    var project = try MeshLabProject.cantileverExample()
    project.analysis = .transient
    project.transientStudy = TransientStudy(
        timeStep: 0.001,
        steps: 2,
        loadFactors: [0, 1, 1]
    )
    project.solverMethod = .numericCoreCholesky
    project.engineeringRequirements = EngineeringRequirements(
        maximumDisplacement: 1,
        maximumRelativeResidual: 1e-6
    )
    let result = try TransientAnalysis(options: project.makeTransientOptions())
        .solve(project.makeModel(), loadHistory: project.makeTransientLoadHistory())
    #expect(result.states.count == 3)
    let csv = AnalysisResultExport.transientCSV(project: project, result: result)
    #expect(csv.hasPrefix("step,time,node,x,y,z,ux,uy,uz,vx,vy,vz,ax,ay,az\n"))
    let artifact = try EngineeringAssessment.run(project)
    #expect(artifact.passed)
    #expect(artifact.result.maximumDisplacement != nil)
}

private extension Load {
    func scaledForTesting(by factor: Double) -> Load {
        switch self {
        case .nodal(let node, let vector):
            .nodal(node: node, vector: vector * factor)
        case .traction(let nodes, let vector):
            .traction(nodes: nodes, vector: vector * factor)
        }
    }
}
