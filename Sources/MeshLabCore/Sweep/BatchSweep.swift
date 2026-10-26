import Foundation

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
        retryFailures: Bool = false
    ) async -> SweepBatchResult {
        let started = Date()
        guard !job.requests.isEmpty else {
            return SweepBatchResult(
                name: job.name,
                elapsedSeconds: Date().timeIntervalSince(started),
                summaries: [],
                resumedRequestCount: 0,
                executedRequestCount: 0
            )
        }
        var summaries = [SweepSummary?](
            repeating: nil,
            count: job.requests.count
        )
        let previousByID = Dictionary(grouping: previous?.summaries ?? [], by: \.id)
        var pending: [Int] = []
        var resumed = 0
        for (index, request) in job.requests.enumerated() {
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
            return SweepBatchResult(
                name: job.name,
                elapsedSeconds: Date().timeIntervalSince(started),
                summaries: summaries.compactMap { $0 },
                resumedRequestCount: resumed,
                executedRequestCount: 0
            )
        }
        let limit = max(1, min(maxConcurrency, pending.count))
        await withTaskGroup(of: (Int, SweepSummary).self) { group in
            var next = 0
            func add(_ pendingIndex: Int) {
                let index = pending[pendingIndex]
                let request = job.requests[index]
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
                if next < pending.count {
                    add(next)
                    next += 1
                }
            }
        }
        return SweepBatchResult(
            name: job.name,
            elapsedSeconds: Date().timeIntervalSince(started),
            summaries: summaries.compactMap { $0 },
            resumedRequestCount: resumed,
            executedRequestCount: pending.count
        )
    }

    /// Deterministic request identity used by resumable workers. FNV-1a keeps
    /// the format dependency-free; this is an identity guard, not a security hash.
    public static func fingerprint(_ request: SweepRequest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(request)) ?? Data(request.id.utf8)
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
                modeCount: project.modalModeCount
            )).solve(project.makeModel())
            modeCount = result.modes.count
            strainEnergy = nil

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
