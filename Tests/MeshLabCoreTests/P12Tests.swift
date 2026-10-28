import Foundation
import MeshLabCore
import Testing
import simd

private func robustProject() throws -> MeshLabProject {
    let mesh = try MeshGenerators.structuredRectangle(
        width: 2,
        height: 1,
        divisions: SIMD2(3, 2)
    )
    let material = try ElasticMaterial(
        youngModulus: 1e7,
        poissonRatio: 0.3,
        thickness: 0.1
    )
    let fixed = mesh.nodeIndices { abs($0.x) < 1e-12 }
        .map { DirichletCondition.fixed(node: $0) }
    let loaded = try #require(mesh.nodeIndices { abs($0.x - 2) < 1e-12 }.first)
    return MeshLabProject(
        name: "Robust beam",
        mesh: mesh,
        material: material,
        constraints: fixed,
        loads: [.nodal(node: loaded, vector: SIMD3<Double>(0, -100, 0))]
    )
}

private func robustStudy() -> RobustDesignStudy {
    RobustDesignStudy(
        axes: [ParametricAxis(parameter: .youngModulus, values: [1e7, 2e7])],
        scenarios: [
            DesignUncertaintyScenario(id: "low", loadMultiplier: 0.5, weight: 1),
            DesignUncertaintyScenario(id: "high", loadMultiplier: 1.5, weight: 1),
        ],
        objective: .compliance,
        minimumReliability: 1,
        variabilityWeight: 1
    )
}

@Test func robustDesignAggregatesWeightedRiskAndSelectsStifferCandidate() throws {
    let project = try robustProject()
    let result = try robustStudy().solve(project)

    #expect(result.candidates.count == 2)
    #expect(result.scenarios.count == 2)
    #expect(result.bestIndex == 1)
    #expect(result.candidates.allSatisfy { $0.reliability == 1 })
    #expect(result.candidates[1].compliance.mean < result.candidates[0].compliance.mean)
    #expect(result.candidates[0].compliance.standardDeviation > 0)
    #expect(result.candidates[0].compliance.worst > result.candidates[0].compliance.mean)
    #expect(result.sweepResult.summaries.count == 4)
    #expect(result.sweepResult.artifactID != nil)
}

@Test func robustDesignDistributesThroughP11DShardsAndReducesIdentically() async throws {
    let project = try robustProject()
    let study = robustStudy()
    let job = try study.makeSweepJob(project: project)
    let first = await SweepRunner.run(job, shardIndex: 0, shardCount: 2)
    let second = await SweepRunner.run(job, shardIndex: 1, shardCount: 2)
    let merged = try SweepRunner.merge([first, second], for: job)
    let distributed = try study.reduce(merged, for: project, job: job)
    let local = try study.solve(project)

    #expect(distributed.bestIndex == local.bestIndex)
    #expect(distributed.candidates == local.candidates)
    #expect(distributed.sweepResult.artifactID == local.sweepResult.artifactID)
}

@Test func robustReliabilityConstraintsAndCSVAreEngineeringTraceable() throws {
    let project = try robustProject()
    let nominal = try StaticAnalysis().solve(project.makeModel())
    var study = robustStudy()
    study.constraints = [ParametricConstraint(
        metric: .maxDisplacement,
        upperBound: nominal.maxDisplacement
    )]
    study.minimumReliability = 0.5
    let result = try study.solve(project)
    #expect(abs(result.candidates[0].reliability - 0.5) < 1e-12)
    #expect(result.candidates[1].reliability == 1)
    let csv = AnalysisResultExport.designCSV(.robust(result))
    #expect(csv.hasPrefix("candidate,feasible,pareto,reliability,youngModulus"))
    #expect(csv.contains("meanCompliance"))
    #expect(csv.split(separator: "\n").count == 3)
}

@Test func schemaFourteenPersistsRobustStudyAndMigratesThirteen() throws {
    var project = try robustProject()
    project.designStudy.kind = .robust
    project.designStudy.robust = robustStudy()
    let encoded = try MeshLabProjectFile.encode(project)
    let decoded = try MeshLabProjectFile.decode(encoded)
    #expect(decoded.schemaVersion == 14)
    #expect(decoded.designStudy == project.designStudy)

    var object = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["schemaVersion"] = 13
    var design = try #require(object["designStudy"] as? [String: Any])
    design["kind"] = "parametric"
    design.removeValue(forKey: "robust")
    object["designStudy"] = design
    let migrated = try MeshLabProjectFile.decode(
        JSONSerialization.data(withJSONObject: object)
    )
    #expect(migrated.schemaVersion == 13)
    #expect(migrated.designStudy.robust == RobustDesignStudy())
}
