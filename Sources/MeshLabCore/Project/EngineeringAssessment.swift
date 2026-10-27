import Foundation
import simd

public struct EngineeringProjectMetadata: Sendable, Hashable, Codable {
    public var identifier: String
    public var revision: String
    public var analyst: String
    public var summary: String

    public init(
        identifier: String = "",
        revision: String = "",
        analyst: String = "",
        summary: String = ""
    ) {
        self.identifier = identifier
        self.revision = revision
        self.analyst = analyst
        self.summary = summary
    }
}

public struct EngineeringRequirements: Sendable, Hashable, Codable {
    public var maximumDisplacement: Double?
    public var maximumVonMises: Double?
    public var maximumTemperature: Double?
    public var minimumFrequency: Double?
    public var maximumRelativeResidual: Double?
    public var minimumMeshQuality: Double?
    public var requireConvergence: Bool

    public init(
        maximumDisplacement: Double? = nil,
        maximumVonMises: Double? = nil,
        maximumTemperature: Double? = nil,
        minimumFrequency: Double? = nil,
        maximumRelativeResidual: Double? = 1e-6,
        minimumMeshQuality: Double? = nil,
        requireConvergence: Bool = true
    ) {
        self.maximumDisplacement = maximumDisplacement
        self.maximumVonMises = maximumVonMises
        self.maximumTemperature = maximumTemperature
        self.minimumFrequency = minimumFrequency
        self.maximumRelativeResidual = maximumRelativeResidual
        self.minimumMeshQuality = minimumMeshQuality
        self.requireConvergence = requireConvergence
    }
}

public enum EngineeringCheckStatus: String, Sendable, Hashable, Codable {
    case passed
    case failed
    case notEvaluated = "not-evaluated"
}

public enum EngineeringCheckKind: String, Sendable, Hashable, Codable {
    case convergence
    case maximumDisplacement
    case maximumVonMises
    case maximumTemperature
    case minimumFrequency
    case maximumRelativeResidual
    case minimumMeshQuality
}

public struct EngineeringCheck: Sendable, Hashable, Codable {
    public let kind: EngineeringCheckKind
    public let status: EngineeringCheckStatus
    public let observed: Double?
    public let limit: Double?
    public let utilization: Double?
    public let message: String
}

public struct EngineeringMeshSummary: Sendable, Hashable, Codable {
    public let nodeCount: Int
    public let elementCount: Int
    public let degreeOfFreedomCount: Int
    public let minimumQuality: Double
    public let invertedElementCount: Int
    public let sourceFormat: String?
    public let lengthUnit: MeshLengthUnit
}

public struct EngineeringResultSummary: Sendable, Hashable, Codable {
    public let maximumDisplacement: Double?
    public let maximumVonMises: Double?
    public let strainEnergy: Double?
    public let maximumTemperature: Double?
    public let minimumFrequency: Double?
    public let maximumRelativeResidual: Double?
    public let converged: Bool
}

public struct EngineeringRunArtifact: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let projectIdentifier: String
    public let projectRevision: String
    public let projectName: String
    public let analyst: String
    public let projectSummary: String
    public let projectSchemaVersion: Int
    public let projectFingerprint: String
    public let analysis: AnalysisKind
    public let solverMethod: SparseSolverMethod
    public let numericContract: String
    public let mesh: EngineeringMeshSummary
    public let result: EngineeringResultSummary
    public let checks: [EngineeringCheck]
    public let passed: Bool

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    public func markdown() -> String {
        var lines = [
            "# Engineering assessment: \(escape(projectName))",
            "",
            "- Project ID: \(escape(projectIdentifier))",
            "- Revision: \(escape(projectRevision))",
            "- Analyst: \(escape(analyst))",
            "- Summary: \(escape(projectSummary))",
            "- Analysis: \(analysis.rawValue)",
            "- Solver: `\(String(describing: solverMethod))`",
            "- Project fingerprint: `\(projectFingerprint)`",
            "- Numeric contract: `\(numericContract)`",
            "- Overall status: **\(passed ? "PASS" : "FAIL")**",
            "",
            "## Model",
            "",
            "| Nodes | Elements | DOFs | Minimum quality | Inverted elements |",
            "| ---: | ---: | ---: | ---: | ---: |",
            "| \(mesh.nodeCount) | \(mesh.elementCount) | \(mesh.degreeOfFreedomCount) | \(number(mesh.minimumQuality)) | \(mesh.invertedElementCount) |",
            "",
            "Stored length unit: `\(mesh.lengthUnit.rawValue)`; source format: `\(mesh.sourceFormat ?? "native")`.",
            "",
            "## Checks",
            "",
            "| Requirement | Status | Observed | Limit | Utilization |",
            "| --- | --- | ---: | ---: | ---: |",
        ]
        for check in checks {
            lines.append([
                escape(check.kind.rawValue),
                check.status.rawValue,
                check.observed.map(number) ?? "—",
                check.limit.map(number) ?? "—",
                check.utilization.map { number(100 * $0) + "%" } ?? "—",
            ].joined(separator: " | ").withTableEdges)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func number(_ value: Double) -> String {
        String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

public enum EngineeringAssessmentError: Error, Equatable, Sendable {
    case invalidRequirement(String)
}

public enum EngineeringAssessment {
    public static func run(_ project: MeshLabProject) throws -> EngineeringRunArtifact {
        try validate(project.engineeringRequirements)
        let quality = project.mesh.qualityReport()
        let result = try solve(project)
        let checks = makeChecks(
            requirements: project.engineeringRequirements,
            quality: quality,
            result: result
        )
        let metadata = project.engineeringMetadata
        return EngineeringRunArtifact(
            schemaVersion: EngineeringRunArtifact.currentSchemaVersion,
            projectIdentifier: metadata.identifier.isEmpty ? project.name : metadata.identifier,
            projectRevision: metadata.revision.isEmpty ? "unrevisioned" : metadata.revision,
            projectName: project.name,
            analyst: metadata.analyst.isEmpty ? "unspecified" : metadata.analyst,
            projectSummary: metadata.summary,
            projectSchemaVersion: project.schemaVersion,
            projectFingerprint: fingerprint(project),
            analysis: project.analysis,
            solverMethod: project.solverMethod,
            numericContract: "swift-numeric-core-1.x",
            mesh: EngineeringMeshSummary(
                nodeCount: project.mesh.nodes.count,
                elementCount: project.mesh.elements.count,
                degreeOfFreedomCount: project.mesh.dofCount,
                minimumQuality: quality.minimumQuality,
                invertedElementCount: quality.invertedElementIndices.count,
                sourceFormat: project.meshMetadata.sourceFormat,
                lengthUnit: project.meshMetadata.lengthUnit
            ),
            result: result,
            checks: checks,
            passed: checks.allSatisfy { $0.status == .passed }
        )
    }

    public static func fingerprint(_ project: MeshLabProject) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(project)) ?? Data(project.name.utf8)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func solve(_ project: MeshLabProject) throws -> EngineeringResultSummary {
        switch project.analysis {
        case .staticAnalysis:
            return staticSummary(try StaticAnalysis(
                options: project.makeAnalysisOptions()
            ).solve(project.makeModel()))

        case .productionLinear:
            let value = try ProductionLinearAnalysis.solve(project: project)
            let residual = value.results.compactMap {
                $0.result.equilibrium.relativeFreeResidual
            }.max()
            return EngineeringResultSummary(
                maximumDisplacement: value.envelope.maximumDisplacement,
                maximumVonMises: value.envelope.maximumVonMises,
                strainEnergy: value.results.map { $0.result.strainEnergy }.max(),
                maximumTemperature: nil,
                minimumFrequency: nil,
                maximumRelativeResidual: residual,
                converged: value.results.allSatisfy { $0.result.solveReport.converged }
            )

        case .nonlinearStatic:
            let value = try NonlinearStaticAnalysis(options: project.nonlinearOptions)
                .solve(project.makeModel())
            return staticSummary(value.staticResult)

        case .coupledThermoMechanical:
            let value = try CoupledThermoMechanicalAnalysis(
                options: project.coupledOptions,
                analysisOptions: project.makeAnalysisOptions(),
                referenceTemperature: project.thermalStudy.referenceTemperature
            ).solve(
                thermal: project.makeThermalModel(),
                structural: project.makeModel()
            )
            let summary = staticSummary(value.staticResult)
            return EngineeringResultSummary(
                maximumDisplacement: summary.maximumDisplacement,
                maximumVonMises: summary.maximumVonMises,
                strainEnergy: summary.strainEnergy,
                maximumTemperature: value.thermalResult.maximumTemperature,
                minimumFrequency: nil,
                maximumRelativeResidual: summary.maximumRelativeResidual,
                converged: value.converged && summary.converged
            )

        case .modal:
            let value = try ModalAnalysis(options: ModalOptions(
                modeCount: project.modalModeCount
            )).solve(project.makeModel())
            return EngineeringResultSummary(
                maximumDisplacement: nil,
                maximumVonMises: nil,
                strainEnergy: nil,
                maximumTemperature: nil,
                minimumFrequency: value.modes.map(\.frequencyHz).min(),
                maximumRelativeResidual: value.modes.map(\.relativeResidual).max(),
                converged: !value.modes.isEmpty
            )

        case .thermalStructural:
            let thermal = try ThermalAnalysis(options: project.makeAnalysisOptions())
                .solve(project.makeThermalModel())
            let stress = try ThermalStressAnalysis(
                options: project.makeAnalysisOptions(),
                referenceTemperature: project.thermalStudy.referenceTemperature
            ).solve(project.makeModel(), temperatures: thermal.temperatures)
            let summary = staticSummary(stress.staticResult)
            return EngineeringResultSummary(
                maximumDisplacement: summary.maximumDisplacement,
                maximumVonMises: summary.maximumVonMises,
                strainEnergy: summary.strainEnergy,
                maximumTemperature: thermal.maximumTemperature,
                minimumFrequency: nil,
                maximumRelativeResidual: max(
                    summary.maximumRelativeResidual ?? 0,
                    thermal.solveReport.relativeResidual ?? 0
                ),
                converged: summary.converged && thermal.solveReport.converged
            )
        }
    }

    private static func staticSummary(_ value: StaticResult) -> EngineeringResultSummary {
        EngineeringResultSummary(
            maximumDisplacement: value.maxDisplacement,
            maximumVonMises: value.maxVonMises,
            strainEnergy: value.strainEnergy,
            maximumTemperature: nil,
            minimumFrequency: nil,
            maximumRelativeResidual: value.equilibrium.relativeFreeResidual,
            converged: value.solveReport.converged
        )
    }

    private static func makeChecks(
        requirements: EngineeringRequirements,
        quality: MeshQualityReport,
        result: EngineeringResultSummary
    ) -> [EngineeringCheck] {
        var checks: [EngineeringCheck] = []
        if requirements.requireConvergence {
            checks.append(EngineeringCheck(
                kind: .convergence,
                status: result.converged ? .passed : .failed,
                observed: result.converged ? 1 : 0,
                limit: 1,
                utilization: result.converged ? 1 : 0,
                message: result.converged ? "Analysis converged" : "Analysis did not converge"
            ))
        }
        appendUpper(
            .maximumDisplacement,
            observed: result.maximumDisplacement,
            limit: requirements.maximumDisplacement,
            into: &checks
        )
        appendUpper(
            .maximumVonMises,
            observed: result.maximumVonMises,
            limit: requirements.maximumVonMises,
            into: &checks
        )
        appendUpper(
            .maximumTemperature,
            observed: result.maximumTemperature,
            limit: requirements.maximumTemperature,
            into: &checks
        )
        appendLower(
            .minimumFrequency,
            observed: result.minimumFrequency,
            limit: requirements.minimumFrequency,
            into: &checks
        )
        appendUpper(
            .maximumRelativeResidual,
            observed: result.maximumRelativeResidual,
            limit: requirements.maximumRelativeResidual,
            into: &checks
        )
        appendLower(
            .minimumMeshQuality,
            observed: quality.minimumQuality,
            limit: requirements.minimumMeshQuality,
            into: &checks
        )
        if quality.invertedElementIndices.count > 0 {
            checks.append(EngineeringCheck(
                kind: .minimumMeshQuality,
                status: .failed,
                observed: Double(quality.invertedElementIndices.count),
                limit: 0,
                utilization: nil,
                message: "Mesh contains inverted elements"
            ))
        }
        return checks
    }

    private static func appendUpper(
        _ kind: EngineeringCheckKind,
        observed: Double?,
        limit: Double?,
        into checks: inout [EngineeringCheck]
    ) {
        guard let limit else { return }
        guard let observed else {
            checks.append(notEvaluated(kind, limit: limit))
            return
        }
        checks.append(EngineeringCheck(
            kind: kind,
            status: observed <= limit ? .passed : .failed,
            observed: observed,
            limit: limit,
            utilization: limit > 0 ? observed / limit : (observed == 0 ? 0 : nil),
            message: observed <= limit ? "Upper limit satisfied" : "Upper limit exceeded"
        ))
    }

    private static func appendLower(
        _ kind: EngineeringCheckKind,
        observed: Double?,
        limit: Double?,
        into checks: inout [EngineeringCheck]
    ) {
        guard let limit else { return }
        guard let observed else {
            checks.append(notEvaluated(kind, limit: limit))
            return
        }
        checks.append(EngineeringCheck(
            kind: kind,
            status: observed >= limit ? .passed : .failed,
            observed: observed,
            limit: limit,
            utilization: observed > 0 ? limit / observed : nil,
            message: observed >= limit ? "Lower limit satisfied" : "Lower limit not met"
        ))
    }

    private static func notEvaluated(
        _ kind: EngineeringCheckKind,
        limit: Double
    ) -> EngineeringCheck {
        EngineeringCheck(
            kind: kind,
            status: .notEvaluated,
            observed: nil,
            limit: limit,
            utilization: nil,
            message: "Configured analysis does not produce this response"
        )
    }

    private static func validate(_ value: EngineeringRequirements) throws {
        let nonNegative: [(String, Double?)] = [
            ("maximum displacement", value.maximumDisplacement),
            ("maximum von Mises stress", value.maximumVonMises),
            ("maximum relative residual", value.maximumRelativeResidual),
        ]
        for (name, limit) in nonNegative {
            if let limit, (!limit.isFinite || limit < 0) {
                throw EngineeringAssessmentError.invalidRequirement(name)
            }
        }
        if let temperature = value.maximumTemperature, !temperature.isFinite {
            throw EngineeringAssessmentError.invalidRequirement("maximum temperature")
        }
        if let frequency = value.minimumFrequency,
           !frequency.isFinite || frequency < 0 {
            throw EngineeringAssessmentError.invalidRequirement("minimum frequency")
        }
        if let quality = value.minimumMeshQuality,
           !quality.isFinite || !(0...1).contains(quality) {
            throw EngineeringAssessmentError.invalidRequirement("minimum mesh quality")
        }
    }
}

private extension String {
    var withTableEdges: String { "| " + self + " |" }
}
