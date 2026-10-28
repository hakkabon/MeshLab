import Foundation
import MeshLabCore
import Testing
import simd

private func executionProject(scale: Double) throws -> MeshLabProject {
    let mesh = try MeshGenerators.structuredRectangle(
        width: 1,
        height: 1,
        divisions: SIMD2(2, 1)
    )
    let material = try ElasticMaterial(
        youngModulus: 1e7,
        poissonRatio: 0.3,
        thickness: 0.1
    )
    let fixed = mesh.nodeIndices { abs($0.x) < 1e-12 }
        .map { DirichletCondition.fixed(node: $0) }
    let loaded = try #require(mesh.nodeIndices { abs($0.x - 1) < 1e-12 }.first)
    return MeshLabProject(
        name: "Execution \(scale)",
        mesh: mesh,
        material: material,
        constraints: fixed,
        loads: [.nodal(node: loaded, vector: SIMD3<Double>(0, -scale, 0))]
    )
}

private func executionJob() throws -> SweepJob {
    SweepJob(name: "P11D", requests: try (1...7).map { index in
        SweepRequest(
            id: "request-\(index)",
            project: try executionProject(scale: Double(index))
        )
    })
}

private actor CheckpointRecorder {
    var values: [SweepCheckpoint] = []
    func append(_ value: SweepCheckpoint) { values.append(value) }
    func snapshot() -> [SweepCheckpoint] { values }
}

@Test func deterministicShardsAreDisjointAndMergeInJobOrder() async throws {
    let job = try executionJob()
    let shards = try (0..<3).map { try SweepRunner.makeShard(job, index: $0, count: 3) }
    let ids = shards.flatMap { $0.job.requests.map(\.id) }
    #expect(Set(ids).count == job.requests.count)
    #expect(Set(ids) == Set(job.requests.map(\.id)))
    #expect(shards.allSatisfy { $0.jobFingerprint == SweepRunner.jobFingerprint(job) })

    var results: [SweepBatchResult] = []
    for shard in shards {
        results.append(await SweepRunner.run(
            job,
            maxConcurrency: 2,
            shardIndex: shard.index,
            shardCount: shard.count
        ))
    }
    let merged = try SweepRunner.merge(results, for: job)
    let direct = await SweepRunner.run(job, maxConcurrency: 2)
    #expect(merged.summaries.map(\.id) == job.requests.map(\.id))
    #expect(merged.summaries.map(\.status) == direct.summaries.map(\.status))
    #expect(merged.summaries.map(\.maxDisplacement) == direct.summaries.map(\.maxDisplacement))
    #expect(merged.artifactID == direct.artifactID)
}

@Test func executionPublishesMonotonicDurableCheckpoints() async throws {
    let job = try executionJob()
    let recorder = CheckpointRecorder()
    let result = await SweepRunner.run(
        job,
        maxConcurrency: 3,
        checkpoint: { checkpoint in await recorder.append(checkpoint) }
    )
    let checkpoints = await recorder.snapshot()
    #expect(checkpoints.count == job.requests.count)
    #expect(checkpoints.map(\.sequence) == Array(1...job.requests.count))
    #expect(checkpoints.map(\.completedRequestCount) == Array(1...job.requests.count))
    #expect(checkpoints.allSatisfy { $0.totalRequestCount == job.requests.count })
    #expect(checkpoints.last?.result.summaries == result.summaries)
    #expect(checkpoints.last?.result.artifactID == result.artifactID)
}

@Test func mergeRejectsDuplicateOrForeignArtifacts() async throws {
    let job = try executionJob()
    let first = await SweepRunner.run(job, shardIndex: 0, shardCount: 2)
    #expect(throws: SweepExecutionError.self) {
        _ = try SweepRunner.merge([first, first], for: job)
    }

    var other = try executionJob()
    other.name = "Different"
    #expect(throws: SweepExecutionError.self) {
        _ = try SweepRunner.merge([first], for: other)
    }
}
