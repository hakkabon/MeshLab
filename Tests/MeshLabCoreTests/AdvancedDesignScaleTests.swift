import Foundation
import MeshLabCore
import Testing
import simd

private func advancedDesignProject(loadScale: Double = 1) throws -> MeshLabProject {
    let mesh = try MeshGenerators.structuredRectangle(
        width: 2,
        height: 1,
        divisions: SIMD2(3, 2)
    )
    let material = try ElasticMaterial(
        youngModulus: 100e9,
        poissonRatio: 0.3,
        thickness: 0.1
    )
    let fixed = mesh.nodeIndices { abs($0.x) < 1e-12 }.map {
        DirichletCondition.fixed(node: $0)
    }
    let loaded = try #require(mesh.nodeIndices { abs($0.x - 2) < 1e-12 }.first)
    return MeshLabProject(
        name: "Advanced design",
        mesh: mesh,
        material: material,
        constraints: fixed,
        loads: [.nodal(node: loaded, vector: SIMD3<Double>(0, -1_000, 0))],
        loadScale: loadScale
    )
}

@Test func constrainedParametricStudyBuildsFeasibleParetoFrontAndCSV() throws {
    let project = try advancedDesignProject()
    let baseline = try StaticAnalysis().solve(project.makeModel())
    let study = ParametricStudy(
        axes: [ParametricAxis(parameter: .loadScale, values: [0.5, 1, 2])],
        objective: .compliance,
        constraints: [ParametricConstraint(
            metric: .maxDisplacement,
            upperBound: baseline.maxDisplacement * 1.1
        )],
        paretoObjectives: [.compliance, .maxVonMises]
    )

    let result = try study.solve(project)

    #expect(result.feasibleSampleCount == 2)
    #expect(result.bestIndex == 0)
    #expect(result.paretoIndices == [0])
    #expect(result.samples.map(\.isFeasible) == [true, true, false])
    let csv = AnalysisResultExport.designCSV(.parametric(result))
    #expect(csv.hasPrefix("sample,feasible,pareto,loadScale"))
    #expect(csv.contains("2,false,false"))
}

@Test func constrainedParametricStudyReportsEmptyFeasibleSet() throws {
    let project = try advancedDesignProject()
    let study = ParametricStudy(
        axes: [ParametricAxis(parameter: .loadScale, values: [1, 2])],
        constraints: [ParametricConstraint(metric: .maxDisplacement, upperBound: 0)]
    )
    #expect(throws: DesignError.self) {
        _ = try study.solve(project)
    }
}

@Test func schemaEightDefaultsAdvancedDesignFieldsFromVersionSeven() throws {
    var project = try advancedDesignProject()
    project.designStudy.parametric = ParametricStudy(
        axes: [ParametricAxis(parameter: .loadScale, values: [0.5, 1])],
        constraints: [ParametricConstraint(metric: .maxVonMises, upperBound: 1e9)],
        paretoObjectives: [.compliance, .maxVonMises]
    )
    let encoded = try MeshLabProjectFile.encode(project)
    let roundTrip = try MeshLabProjectFile.decode(encoded)
    #expect(roundTrip == project)
    #expect(roundTrip.schemaVersion == 8)

    var object = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["schemaVersion"] = 7
    var design = try #require(object["designStudy"] as? [String: Any])
    var parametric = try #require(design["parametric"] as? [String: Any])
    parametric.removeValue(forKey: "constraints")
    parametric.removeValue(forKey: "paretoObjectives")
    design["parametric"] = parametric
    object["designStudy"] = design
    let migrated = try MeshLabProjectFile.decode(
        try JSONSerialization.data(withJSONObject: object)
    )
    #expect(migrated.schemaVersion == 7)
    #expect(migrated.designStudy.parametric.constraints.isEmpty)
    #expect(migrated.designStudy.parametric.paretoObjectives == ParametricObjective.allCases)
}

@Test func sweepResumeReusesOnlyMatchingRequestFingerprints() async throws {
    let first = SweepRequest(id: "first", project: try advancedDesignProject())
    let second = SweepRequest(id: "second", project: try advancedDesignProject(loadScale: 2))
    let original = SweepJob(name: "resumable", requests: [first, second])
    let previous = await SweepRunner.run(original, maxConcurrency: 2)

    let fullyResumed = await SweepRunner.run(
        original,
        maxConcurrency: 2,
        resuming: previous
    )
    #expect(fullyResumed.resumedRequestCount == 2)
    #expect(fullyResumed.executedRequestCount == 0)
    #expect(fullyResumed.summaries == previous.summaries)

    let changed = SweepRequest(
        id: "second",
        project: try advancedDesignProject(loadScale: 3)
    )
    let partiallyResumed = await SweepRunner.run(
        SweepJob(name: "resumable", requests: [first, changed]),
        maxConcurrency: 2,
        resuming: previous
    )
    #expect(partiallyResumed.resumedRequestCount == 1)
    #expect(partiallyResumed.executedRequestCount == 1)
    #expect(partiallyResumed.summaries.map(\.id) == ["first", "second"])
    #expect(partiallyResumed.summaries[1].requestFingerprint
        == SweepRunner.fingerprint(changed))
}

@Test func sweepResumeCanRetryMatchingFailures() async throws {
    var invalid = try advancedDesignProject()
    invalid.constraints = []
    let job = SweepJob(name: "retry", requests: [
        SweepRequest(id: "invalid", project: invalid),
    ])
    let previous = await SweepRunner.run(job, maxConcurrency: 1)
    #expect(previous.summaries.first?.status == .failed)

    let reused = await SweepRunner.run(job, resuming: previous)
    #expect(reused.resumedRequestCount == 1)
    #expect(reused.executedRequestCount == 0)

    let retried = await SweepRunner.run(
        job,
        resuming: previous,
        retryFailures: true
    )
    #expect(retried.resumedRequestCount == 0)
    #expect(retried.executedRequestCount == 1)
    #expect(retried.summaries.first?.status == .failed)
}

@Test func legacySweepResultsDecodeButAreNotUnsafelyResumed() async throws {
    let request = SweepRequest(id: "legacy", project: try advancedDesignProject())
    let job = SweepJob(name: "legacy", requests: [request])
    let current = await SweepRunner.run(job, maxConcurrency: 1)
    var object = try #require(
        try JSONSerialization.jsonObject(with: SweepJobFile.encode(current))
            as? [String: Any]
    )
    object.removeValue(forKey: "resumedRequestCount")
    object.removeValue(forKey: "executedRequestCount")
    var summaries = try #require(object["summaries"] as? [[String: Any]])
    summaries[0].removeValue(forKey: "requestFingerprint")
    object["summaries"] = summaries
    let legacy = try SweepJobFile.decodeResult(
        try JSONSerialization.data(withJSONObject: object)
    )

    #expect(legacy.resumedRequestCount == nil)
    #expect(legacy.summaries.first?.requestFingerprint == nil)
    let rerun = await SweepRunner.run(job, resuming: legacy)
    #expect(rerun.resumedRequestCount == 0)
    #expect(rerun.executedRequestCount == 1)
}
