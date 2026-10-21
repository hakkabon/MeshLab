import Foundation
import Testing
import simd
@testable import MeshLabCore

@Test func matrixFreeStaticMatchesAssembledSolve() throws {
    let project = try MeshLabProject.cantileverExample()
    let direct = try StaticAnalysis(options: project.makeAnalysisOptions())
        .solve(project.makeModel())

    let matrixFree = try StaticAnalysis(options: AnalysisOptions(
        matrixFreeOptions: MatrixFreeOptions(
            maximumIterations: 2_000,
            relativeTolerance: 1e-10
        )
    )).solve(project.makeModel())

    #expect(matrixFree.solveReport.iterations != nil)
    #expect(matrixFree.solveReport.relativeResidual ?? 1 < 1e-9)
    #expect(matrixFree.displacements.count == direct.displacements.count)
    let difference = zip(matrixFree.displacements, direct.displacements).reduce(0.0) {
        $0 + simd_length($1.0 - $1.1)
    }
    let reference = direct.displacements.reduce(0.0) {
        $0 + simd_length($1)
    }
    #expect(difference / reference < 1e-7)
    #expect(abs(matrixFree.maxVonMises - direct.maxVonMises)
        / direct.maxVonMises < 1e-7)
    #expect(abs(matrixFree.strainEnergy - direct.strainEnergy)
        / direct.strainEnergy < 1e-7)
}

@Test func matrixFreeStaticHandlesPrescribedValues() throws {
    let mesh = try MeshGenerators.structuredRectangle(
        width: 2,
        height: 1,
        divisions: SIMD2(4, 2)
    )
    let material = try ElasticMaterial(
        youngModulus: 100e9,
        poissonRatio: 0.3,
        thickness: 1
    )
    let constraints = mesh.nodeIndices { abs($0.x) < 1e-12 }
        .flatMap { node in
            [
                DirichletCondition(node: node, axis: 0, value: 0.001),
                DirichletCondition(node: node, axis: 1, value: -0.0005),
            ]
        }
    let right = try #require(mesh.nodeIndices { abs($0.x - 2) < 1e-12 }.first)
    let model = FEMModel(
        mesh: mesh,
        material: material,
        constraints: constraints,
        loads: [Load.nodal(node: right, vector: SIMD3<Double>(0, 1_000, 0))]
    )
    let direct = try StaticAnalysis().solve(model)
    let matrixFree = try StaticAnalysis(options: AnalysisOptions(
        matrixFreeOptions: MatrixFreeOptions(
            maximumIterations: 2_000,
            relativeTolerance: 1e-11
        )
    )).solve(model)

    let difference = zip(matrixFree.displacements, direct.displacements).reduce(0.0) {
        $0 + simd_length($1.0 - $1.1)
    }
    #expect(difference < 1e-10)
}

private func sweepProject(loadScale: Double = 1) throws -> MeshLabProject {
    let mesh = try MeshGenerators.structuredRectangle(
        width: 2,
        height: 1,
        divisions: SIMD2(4, 2)
    )
    let material = try ElasticMaterial(
        youngModulus: 100e9,
        poissonRatio: 0.3,
        thickness: 1
    )
    let constraints = mesh.nodeIndices { abs($0.x) < 1e-12 }
        .map { DirichletCondition.fixed(node: $0) }
    let right = try #require(mesh.nodeIndices { abs($0.x - 2) < 1e-12 }.first)
    return MeshLabProject(
        name: "Sweep",
        mesh: mesh,
        material: material,
        constraints: constraints,
        loads: [Load.nodal(node: right, vector: SIMD3<Double>(0, -1_000, 0))],
        loadScale: loadScale
    )
}

@Test func batchSweepRunsConcurrentlyAndPreservesOrder() async throws {
    var heavier = try sweepProject(loadScale: 2)
    heavier.name = "Heavier"
    var designProject = try sweepProject()
    designProject.designStudy.kind = .parametric
    designProject.designStudy.parametric = ParametricStudy(axes: [
        ParametricAxis(parameter: .loadScale, values: [0.5, 1]),
    ])
    let job = SweepJob(name: "Scale validation", requests: [
        SweepRequest(id: "baseline", project: try sweepProject()),
        SweepRequest(id: "heavier", project: heavier),
        SweepRequest(id: "parametric", project: designProject, task: .design),
    ])

    let result = await SweepRunner.run(job, maxConcurrency: 2)
    #expect(result.summaries.map(\.id) == ["baseline", "heavier", "parametric"])
    #expect(result.summaries.allSatisfy { $0.status == .succeeded })
    let baseline = try #require(result.summaries.first)
    let heavierSummary = try #require(result.summaries.dropFirst().first)
    #expect((heavierSummary.maxDisplacement ?? 0)
        > (baseline.maxDisplacement ?? 0) * 1.9)
    let parametric = try #require(result.summaries.last)
    #expect(parametric.bestParametricIndex == 0)
    #expect(parametric.finalCompliance != nil)
}

@Test func sweepJobAndResultRoundTripThroughJSON() async throws {
    let job = SweepJob(name: "Round trip", requests: [
        SweepRequest(id: "one", project: try sweepProject()),
    ])
    let decodedJob = try SweepJobFile.decode(try SweepJobFile.encode(job))
    #expect(decodedJob == job)

    let result = await SweepRunner.run(decodedJob, maxConcurrency: 1)
    let decodedResult = try SweepJobFile.decodeResult(
        try SweepJobFile.encode(result)
    )
    #expect(decodedResult == result)
}

@Test func batchSweepCapturesFailures() async throws {
    var invalid = try sweepProject()
    invalid.constraints = []
    let job = SweepJob(name: "Failure", requests: [
        SweepRequest(id: "bad", project: invalid),
    ])
    let result = await SweepRunner.run(job, maxConcurrency: 1)
    let summary = try #require(result.summaries.first)
    #expect(summary.status == .failed)
    #expect(summary.error != nil)
}

@Test func matrixFreeThermalStressMatchesAssembledSolve() throws {
    let project = try MeshLabProject.cantileverExample()
    let thermal = try ThermalAnalysis(options: project.makeAnalysisOptions())
        .solve(project.makeThermalModel())
    let direct = try ThermalStressAnalysis(
        options: project.makeAnalysisOptions(),
        referenceTemperature: project.thermalStudy.referenceTemperature
    ).solve(project.makeModel(), temperatures: thermal.temperatures)
    var matrixFreeOptions = project.makeAnalysisOptions()
    matrixFreeOptions.matrixFreeOptions = MatrixFreeOptions(
        maximumIterations: 2_000,
        relativeTolerance: 1e-10
    )
    let matrixFree = try ThermalStressAnalysis(
        options: matrixFreeOptions,
        referenceTemperature: project.thermalStudy.referenceTemperature
    ).solve(project.makeModel(), temperatures: thermal.temperatures)

    let difference = zip(
        matrixFree.staticResult.displacements,
        direct.staticResult.displacements
    ).reduce(0.0) {
        $0 + simd_length($1.0 - $1.1)
    }
    let reference = direct.staticResult.displacements.reduce(0.0) {
        $0 + simd_length($1)
    }
    #expect(difference / reference < 1e-7)
}
