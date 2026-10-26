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
}

public struct SweepBatchResult: Sendable, Hashable, Codable {
    public let name: String
    public let elapsedSeconds: Double
    public let summaries: [SweepSummary]
}

/// Runs a sweep request without throwing. Failures travel as structured
/// summaries so a cloud worker can report partial progress.
public enum SweepRunner {
    public static func run(_ request: SweepRequest) -> SweepSummary {
        let started = Date()
        do {
            switch request.task {
            case .analysis:
                return try runAnalysis(request, started: started)
            case .design:
                return try runDesign(request, started: started)
            }
        } catch {
            return SweepSummary(
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
        }
    }

    /// Executes a job with bounded concurrency while preserving request order.
    public static func run(
        _ job: SweepJob,
        maxConcurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)
    ) async -> SweepBatchResult {
        let started = Date()
        guard !job.requests.isEmpty else {
            return SweepBatchResult(
                name: job.name,
                elapsedSeconds: Date().timeIntervalSince(started),
                summaries: []
            )
        }
        let limit = max(1, min(maxConcurrency, job.requests.count))
        var summaries = [SweepSummary?](
            repeating: nil,
            count: job.requests.count
        )
        await withTaskGroup(of: (Int, SweepSummary).self) { group in
            var next = 0
            func add(_ index: Int) {
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
                if next < job.requests.count {
                    add(next)
                    next += 1
                }
            }
        }
        return SweepBatchResult(
            name: job.name,
            elapsedSeconds: Date().timeIntervalSince(started),
            summaries: summaries.compactMap { $0 }
        )
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
