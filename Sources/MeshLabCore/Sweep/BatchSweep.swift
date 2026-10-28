import Foundation
import simd

public enum SweepTaskKind: String, Sendable, Hashable, Codable, CaseIterable {
    case analysis
    case design
}

public struct SweepRequest: Sendable, Equatable, Codable {
    public var id: String
    public var project: MeshLabProject
    public var task: SweepTaskKind

    public init(
        id: String,
        project: MeshLabProject,
        task: SweepTaskKind = .analysis
    ) {
        self.id = id
        self.project = project
        self.task = task
    }
}

public struct SweepJob: Sendable, Equatable, Codable {
    public var name: String
    public var requests: [SweepRequest]

    public init(name: String, requests: [SweepRequest]) {
        self.name = name
        self.requests = requests
    }
}

public enum SweepStatus: String, Sendable, Hashable, Codable {
    case succeeded
    case failed
}

public struct SweepSummary: Sendable, Hashable, Codable {
    public let id: String
    public let projectName: String
    public let task: SweepTaskKind
    public let analysis: AnalysisKind
    public let designKind: DesignStudyKind?
    public let status: SweepStatus
    public let elapsedSeconds: Double
    public let error: String?
    public let maxDisplacement: Double?
    public let maxVonMises: Double?
    public let strainEnergy: Double?
    public let maxTemperature: Double?
    public let modeCount: Int?
    public let bestParametricIndex: Int?
    public let finalCompliance: Double?
    public let volumeFraction: Double?
    public let iterations: Int?
    /// Stable hash of the request definition used to guard resume reuse.
    public var requestFingerprint: String? = nil
}

public struct SweepBatchResult: Sendable, Hashable, Codable {
    public let name: String
    public let elapsedSeconds: Double
    public let summaries: [SweepSummary]
    public var resumedRequestCount: Int? = nil
    public var executedRequestCount: Int? = nil
    /// Deterministic identity of the complete, unsharded job definition.
    public var jobFingerprint: String? = nil
    public var shardIndex: Int? = nil
    public var shardCount: Int? = nil
    /// Content identity of ordered numerical outcomes; excludes wall-clock time.
    public var artifactID: String? = nil
}

public struct SweepCheckpoint: Sendable, Hashable, Codable {
    public let sequence: Int
    public let completedRequestCount: Int
    public let totalRequestCount: Int
    public let result: SweepBatchResult
}

public enum SweepExecutionError: Error, Equatable, Sendable {
    case invalidShard(index: Int, count: Int)
    case incompatibleResult(String)
    case duplicateRequest(String)
    case missingRequest(String)
}

public struct SweepShard: Sendable, Codable {
    public let job: SweepJob
    public let jobFingerprint: String
    public let index: Int
    public let count: Int
}

private struct SweepArtifactRecord: Encodable {
    let id: String
    let requestFingerprint: String?
    let status: SweepStatus
    let error: String?
    let maxDisplacement: Double?
    let maxVonMises: Double?
    let strainEnergy: Double?
    let maxTemperature: Double?
    let modeCount: Int?
    let bestParametricIndex: Int?
    let finalCompliance: Double?
    let volumeFraction: Double?
    let iterations: Int?
}

/// Runs a sweep request without throwing. Failures travel as structured
/// summaries so a cloud worker can report partial progress.
public enum SweepRunner {
    public static func run(_ request: SweepRequest) -> SweepSummary {
        let started = Date()
        let fingerprint = fingerprint(request)
        do {
            switch request.task {
            case .analysis:
                var summary = try runAnalysis(request, started: started)
                summary.requestFingerprint = fingerprint
                return summary
            case .design:
                var summary = try runDesign(request, started: started)
                summary.requestFingerprint = fingerprint
                return summary
            }
        } catch {
            var summary = SweepSummary(
                id: request.id,
                projectName: request.project.name,
                task: request.task,
                analysis: request.project.analysis,
                designKind: request.task == .design
                    ? request.project.designStudy.kind
                    : nil,
                status: .failed,
                elapsedSeconds: Date().timeIntervalSince(started),
                error: describe(error),
                maxDisplacement: nil,
                maxVonMises: nil,
                strainEnergy: nil,
                maxTemperature: nil,
                modeCount: nil,
                bestParametricIndex: nil,
                finalCompliance: nil,
                volumeFraction: nil,
                iterations: nil
            )
            summary.requestFingerprint = fingerprint
            return summary
        }
    }

    /// Executes a job with bounded concurrency while preserving request order.
    /// A matching fingerprint from `previous` is reused. Failed prior requests
    /// are reused unless `retryFailures` is true.
    public static func run(
        _ job: SweepJob,
        maxConcurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        resuming previous: SweepBatchResult? = nil,
        retryFailures: Bool = false,
        shardIndex: Int = 0,
        shardCount: Int = 1,
        checkpoint: (@Sendable (SweepCheckpoint) async -> Void)? = nil
    ) async -> SweepBatchResult {
        let started = Date()
        let completeJobFingerprint = jobFingerprint(job)
        let shard: SweepShard
        do {
            shard = try makeShard(job, index: shardIndex, count: shardCount)
        } catch {
            var failed = SweepBatchResult(
                name: job.name,
                elapsedSeconds: Date().timeIntervalSince(started),
                summaries: [],
                resumedRequestCount: 0,
                executedRequestCount: 0
            )
            failed.jobFingerprint = completeJobFingerprint
            failed.shardIndex = shardIndex
            failed.shardCount = shardCount
            failed.artifactID = artifactID(failed)
            return failed
        }
        let executionJob = shard.job
        guard !executionJob.requests.isEmpty else {
            var empty = SweepBatchResult(
                name: job.name,
                elapsedSeconds: Date().timeIntervalSince(started),
                summaries: [],
                resumedRequestCount: 0,
                executedRequestCount: 0
            )
            empty.jobFingerprint = completeJobFingerprint
            empty.shardIndex = shardIndex
            empty.shardCount = shardCount
            empty.artifactID = artifactID(empty)
            return empty
        }
        var summaries = [SweepSummary?](
            repeating: nil,
            count: executionJob.requests.count
        )
        let previousByID = Dictionary(grouping: previous?.summaries ?? [], by: \.id)
        var pending: [Int] = []
        var resumed = 0
        for (index, request) in executionJob.requests.enumerated() {
            let fingerprint = fingerprint(request)
            let reusable = previousByID[request.id]?.first {
                $0.requestFingerprint == fingerprint
                    && ($0.status == .succeeded || !retryFailures)
            }
            if let reusable {
                summaries[index] = reusable
                resumed += 1
            } else {
                pending.append(index)
            }
        }
        guard !pending.isEmpty else {
            var result = SweepBatchResult(
                name: job.name,
                elapsedSeconds: Date().timeIntervalSince(started),
                summaries: summaries.compactMap { $0 },
                resumedRequestCount: resumed,
                executedRequestCount: 0
            )
            result.jobFingerprint = completeJobFingerprint
            result.shardIndex = shardIndex
            result.shardCount = shardCount
            result.artifactID = artifactID(result)
            return result
        }
        let limit = max(1, min(maxConcurrency, pending.count))
        await withTaskGroup(of: (Int, SweepSummary).self) { group in
            var next = 0
            func add(_ pendingIndex: Int) {
                let index = pending[pendingIndex]
                let request = executionJob.requests[index]
                group.addTask {
                    (index, SweepRunner.run(request))
                }
            }
            while next < limit {
                add(next)
                next += 1
            }
            while let (index, summary) = await group.next() {
                summaries[index] = summary
                if let checkpoint {
                    var partial = SweepBatchResult(
                        name: job.name,
                        elapsedSeconds: Date().timeIntervalSince(started),
                        summaries: summaries.compactMap { $0 },
                        resumedRequestCount: resumed,
                        executedRequestCount: summaries.compactMap { $0 }.count - resumed
                    )
                    partial.jobFingerprint = completeJobFingerprint
                    partial.shardIndex = shardIndex
                    partial.shardCount = shardCount
                    partial.artifactID = artifactID(partial)
                    await checkpoint(SweepCheckpoint(
                        sequence: summaries.compactMap { $0 }.count,
                        completedRequestCount: summaries.compactMap { $0 }.count,
                        totalRequestCount: executionJob.requests.count,
                        result: partial
                    ))
                }
                if next < pending.count {
                    add(next)
                    next += 1
                }
            }
        }
        var result = SweepBatchResult(
            name: job.name,
            elapsedSeconds: Date().timeIntervalSince(started),
            summaries: summaries.compactMap { $0 },
            resumedRequestCount: resumed,
            executedRequestCount: pending.count
        )
        result.jobFingerprint = completeJobFingerprint
        result.shardIndex = shardIndex
        result.shardCount = shardCount
        result.artifactID = artifactID(result)
        return result
    }

    /// Stable job identity including request order and all project definitions.
    public static func jobFingerprint(_ job: SweepJob) -> String {
        stableHash(job, fallback: job.name)
    }

    /// Partitions requests by request identity. The assignment is independent
    /// of worker count, scheduling order, or process lifetime.
    public static func makeShard(
        _ job: SweepJob,
        index: Int,
        count: Int
    ) throws -> SweepShard {
        guard count > 0, index >= 0, index < count else {
            throw SweepExecutionError.invalidShard(index: index, count: count)
        }
        let selected = job.requests.filter { request in
            let value = UInt64(fingerprint(request), radix: 16) ?? 0
            return Int(value % UInt64(count)) == index
        }
        return SweepShard(
            job: SweepJob(name: job.name, requests: selected),
            jobFingerprint: jobFingerprint(job),
            index: index,
            count: count
        )
    }

    /// Merges independently executed shards into original request order.
    public static func merge(
        _ results: [SweepBatchResult],
        for job: SweepJob
    ) throws -> SweepBatchResult {
        let expectedFingerprint = jobFingerprint(job)
        var byID: [String: SweepSummary] = [:]
        for result in results {
            guard result.jobFingerprint == expectedFingerprint else {
                throw SweepExecutionError.incompatibleResult(result.name)
            }
            for summary in result.summaries {
                guard byID[summary.id] == nil else {
                    throw SweepExecutionError.duplicateRequest(summary.id)
                }
                byID[summary.id] = summary
            }
        }
        let ordered = try job.requests.map { request in
            guard let summary = byID[request.id],
                  summary.requestFingerprint == fingerprint(request) else {
                throw SweepExecutionError.missingRequest(request.id)
            }
            return summary
        }
        var merged = SweepBatchResult(
            name: job.name,
            elapsedSeconds: results.map(\.elapsedSeconds).max() ?? 0,
            summaries: ordered,
            resumedRequestCount: results.compactMap(\.resumedRequestCount).reduce(0, +),
            executedRequestCount: results.compactMap(\.executedRequestCount).reduce(0, +)
        )
        merged.jobFingerprint = expectedFingerprint
        merged.shardIndex = nil
        merged.shardCount = results.first?.shardCount
        merged.artifactID = artifactID(merged)
        return merged
    }

    /// Deterministic identity for result content. Timing and shard placement
    /// are intentionally excluded so equivalent executions converge.
    public static func artifactID(_ result: SweepBatchResult) -> String {
        let records = result.summaries.map { summary in
            SweepArtifactRecord(
                id: summary.id,
                requestFingerprint: summary.requestFingerprint,
                status: summary.status,
                error: summary.error,
                maxDisplacement: summary.maxDisplacement,
                maxVonMises: summary.maxVonMises,
                strainEnergy: summary.strainEnergy,
                maxTemperature: summary.maxTemperature,
                modeCount: summary.modeCount,
                bestParametricIndex: summary.bestParametricIndex,
                finalCompliance: summary.finalCompliance,
                volumeFraction: summary.volumeFraction,
                iterations: summary.iterations
            )
        }
        return stableHash(records, fallback: result.name)
    }

    /// Deterministic request identity used by resumable workers. FNV-1a keeps
    /// the format dependency-free; this is an identity guard, not a security hash.
    public static func fingerprint(_ request: SweepRequest) -> String {
        stableHash(request, fallback: request.id)
    }

    private static func stableHash<Value: Encodable>(
        _ value: Value,
        fallback: String
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data(fallback.utf8)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func runAnalysis(
        _ request: SweepRequest,
        started: Date
    ) throws -> SweepSummary {
        let project = request.project
        var maxDisplacement: Double?
        var maxVonMises: Double?
        var strainEnergy: Double?
        var maxTemperature: Double?
        var modeCount: Int?

        switch project.analysis {
        case .staticAnalysis:
            let result = try StaticAnalysis(options: project.makeAnalysisOptions())
                .solve(project.makeModel())
            maxDisplacement = result.maxDisplacement
            maxVonMises = result.maxVonMises
            strainEnergy = result.strainEnergy

        case .productionLinear:
            let result = try ProductionLinearAnalysis.solve(project: project)
            maxDisplacement = result.envelope.maximumDisplacement
            maxVonMises = result.envelope.maximumVonMises
            strainEnergy = result.results.map { $0.result.strainEnergy }.max()

        case .nonlinearStatic:
            let result = try NonlinearStaticAnalysis(options: project.nonlinearOptions)
                .solve(project.makeModel()).staticResult
            maxDisplacement = result.maxDisplacement
            maxVonMises = result.maxVonMises
            strainEnergy = result.strainEnergy

        case .coupledThermoMechanical:
            let result = try CoupledThermoMechanicalAnalysis(
                options: project.coupledOptions,
                analysisOptions: project.makeAnalysisOptions(),
                referenceTemperature: project.thermalStudy.referenceTemperature
            ).solve(
                thermal: project.makeThermalModel(),
                structural: project.makeModel()
            )
            maxTemperature = result.thermalResult.maximumTemperature
            maxDisplacement = result.staticResult.maxDisplacement
            maxVonMises = result.staticResult.maxVonMises
            strainEnergy = result.staticResult.strainEnergy

        case .modal:
            let result = try ModalAnalysis(options: ModalOptions(
                modeCount: project.modalModeCount,
                solver: project.modalSolver
            )).solve(project.makeModel())
            modeCount = result.modes.count
            strainEnergy = nil

        case .transient:
            let result: TransientResult
            if project.transientStudy.thermalCoupling {
                let coupled = try TransientThermoMechanicalAnalysis(
                    thermalOptions: project.makeTransientThermalOptions(),
                    structuralOptions: project.makeTransientOptions(),
                    analysisOptions: project.makeAnalysisOptions(),
                    referenceTemperature: project.thermalStudy.referenceTemperature
                ).solve(
                    thermal: project.makeThermalModel(),
                    structural: project.makeModel(),
                    loadHistory: project.makeTransientLoadHistory(),
                    heatFactors: project.makeTransientHeatFactors(),
                    initialTemperature: project.transientStudy.initialTemperature
                )
                result = coupled.structural
                maxTemperature = coupled.thermal.states.map(\.maximumTemperature).max()
            } else {
                result = try TransientAnalysis(options: project.makeTransientOptions())
                    .solve(
                        project.makeModel(),
                        loadHistory: project.makeTransientLoadHistory()
                    )
            }
            maxDisplacement = result.states.flatMap(\.displacement).reduce(0.0) {
                max($0, simd_length($1))
            }
            strainEnergy = result.states.map(\.strainEnergy).max()

        case .thermalStructural:
            let thermal = try ThermalAnalysis(options: project.makeAnalysisOptions())
                .solve(project.makeThermalModel())
            let stress = try ThermalStressAnalysis(
                options: project.makeAnalysisOptions(),
                referenceTemperature: project.thermalStudy.referenceTemperature
            ).solve(project.makeModel(), temperatures: thermal.temperatures)
            maxTemperature = thermal.maximumTemperature
            maxDisplacement = stress.staticResult.maxDisplacement
            maxVonMises = stress.staticResult.maxVonMises
            strainEnergy = stress.staticResult.strainEnergy
        }

        return SweepSummary(
            id: request.id,
            projectName: project.name,
            task: request.task,
            analysis: project.analysis,
            designKind: nil,
            status: .succeeded,
            elapsedSeconds: Date().timeIntervalSince(started),
            error: nil,
            maxDisplacement: maxDisplacement,
            maxVonMises: maxVonMises,
            strainEnergy: strainEnergy,
            maxTemperature: maxTemperature,
            modeCount: modeCount,
            bestParametricIndex: nil,
            finalCompliance: nil,
            volumeFraction: nil,
            iterations: nil
        )
    }

    private static func runDesign(
        _ request: SweepRequest,
        started: Date
    ) throws -> SweepSummary {
        let project = request.project
        let outcome = try project.designStudy.run(on: project)
        var maxDisplacement: Double?
        var maxVonMises: Double?
        var strainEnergy: Double?
        var bestParametricIndex: Int?
        var finalCompliance: Double?
        var volumeFraction: Double?
        var iterations: Int?

        switch outcome {
        case .parametric(let result):
            bestParametricIndex = result.bestIndex
            maxDisplacement = result.best?.maxDisplacement
            maxVonMises = result.best?.maxVonMises
            strainEnergy = result.best?.strainEnergy
            finalCompliance = result.best?.compliance
        case .topology(let result):
            finalCompliance = result.finalCompliance
            volumeFraction = result.volumeFraction
            iterations = result.iterations.count
            maxDisplacement = result.finalResult.maxDisplacement
            maxVonMises = result.finalResult.maxVonMises
            strainEnergy = result.finalResult.strainEnergy
        case .shape(let result):
            finalCompliance = result.finalCompliance
            volumeFraction = result.volumeFraction
            iterations = result.iterations.count
            maxDisplacement = result.staticResult.maxDisplacement
            maxVonMises = result.staticResult.maxVonMises
            strainEnergy = result.staticResult.strainEnergy
        }

        return SweepSummary(
            id: request.id,
            projectName: project.name,
            task: request.task,
            analysis: project.analysis,
            designKind: project.designStudy.kind,
            status: .succeeded,
            elapsedSeconds: Date().timeIntervalSince(started),
            error: nil,
            maxDisplacement: maxDisplacement,
            maxVonMises: maxVonMises,
            strainEnergy: strainEnergy,
            maxTemperature: nil,
            modeCount: nil,
            bestParametricIndex: bestParametricIndex,
            finalCompliance: finalCompliance,
            volumeFraction: volumeFraction,
            iterations: iterations
        )
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

public enum SweepJobFile {
    public static func encode(_ job: SweepJob) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(job)
    }

    public static func decode(_ data: Data) throws -> SweepJob {
        try JSONDecoder().decode(SweepJob.self, from: data)
    }

    public static func encode(_ result: SweepBatchResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(result)
    }

    public static func decodeResult(_ data: Data) throws -> SweepBatchResult {
        try JSONDecoder().decode(SweepBatchResult.self, from: data)
    }
}
