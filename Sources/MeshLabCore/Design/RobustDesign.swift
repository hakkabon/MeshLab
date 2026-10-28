import Foundation

public struct DesignUncertaintyScenario: Sendable, Hashable, Codable {
    public var id: String
    public var loadMultiplier: Double
    public var youngModulusMultiplier: Double
    public var weight: Double

    public init(
        id: String,
        loadMultiplier: Double = 1,
        youngModulusMultiplier: Double = 1,
        weight: Double = 1
    ) {
        self.id = id
        self.loadMultiplier = loadMultiplier
        self.youngModulusMultiplier = youngModulusMultiplier
        self.weight = weight
    }
}

public struct RobustMetricSummary: Sendable, Hashable {
    public let mean: Double
    public let standardDeviation: Double
    public let worst: Double
}

public struct RobustDesignCandidate: Sendable, Hashable {
    public let index: Int
    public let values: [Double]
    public let compliance: RobustMetricSummary
    public let maxDisplacement: RobustMetricSummary
    public let maxVonMises: RobustMetricSummary
    public let reliability: Double
    public let robustObjective: Double
    public let isFeasible: Bool
}

public struct RobustDesignResult: Sendable {
    public let axes: [ParametricAxis]
    public let scenarios: [DesignUncertaintyScenario]
    public let candidates: [RobustDesignCandidate]
    public let objective: ParametricObjective
    public let bestIndex: Int
    public let paretoIndices: [Int]
    public let sweepResult: SweepBatchResult
    public let bestModel: FEMModel
    public let bestResult: StaticResult

    public var best: RobustDesignCandidate? {
        candidates.indices.contains(bestIndex) ? candidates[bestIndex] : nil
    }
}

/// Discrete robust-design orchestration. Candidate/scenario analyses are plain
/// P11D requests, so the same definition can run locally or as durable shards.
public struct RobustDesignStudy: Sendable, Hashable, Codable {
    public var axes: [ParametricAxis]
    public var scenarios: [DesignUncertaintyScenario]
    public var objective: ParametricObjective
    public var constraints: [ParametricConstraint]
    public var minimumReliability: Double
    /// Penalizes objective standard deviation: mean + weight * sigma.
    public var variabilityWeight: Double

    public init(
        axes: [ParametricAxis] = [],
        scenarios: [DesignUncertaintyScenario] = [
            DesignUncertaintyScenario(id: "nominal"),
        ],
        objective: ParametricObjective = .compliance,
        constraints: [ParametricConstraint] = [],
        minimumReliability: Double = 1,
        variabilityWeight: Double = 1
    ) {
        self.axes = axes
        self.scenarios = scenarios
        self.objective = objective
        self.constraints = constraints
        self.minimumReliability = minimumReliability
        self.variabilityWeight = variabilityWeight
    }

    public func validate() throws {
        guard !axes.isEmpty,
              Set(axes.map(\.parameter)).count == axes.count else {
            throw DesignError.invalidStudy("Robust design needs unique non-empty axes")
        }
        guard !scenarios.isEmpty,
              Set(scenarios.map(\.id)).count == scenarios.count,
              scenarios.allSatisfy({
                  !$0.id.isEmpty && $0.loadMultiplier.isFinite
                      && $0.loadMultiplier >= 0
                      && $0.youngModulusMultiplier.isFinite
                      && $0.youngModulusMultiplier > 0
                      && $0.weight.isFinite && $0.weight > 0
              }) else {
            throw DesignError.invalidStudy("Robust scenarios must be unique and positive")
        }
        guard minimumReliability.isFinite, (0...1).contains(minimumReliability),
              variabilityWeight.isFinite, variabilityWeight >= 0 else {
            throw DesignError.invalidStudy("Invalid robust reliability or variability weight")
        }
        guard Set(constraints.map(\.metric)).count == constraints.count,
              constraints.allSatisfy({ $0.upperBound.isFinite && $0.upperBound >= 0 }) else {
            throw DesignError.invalidStudy("Invalid robust response constraints")
        }
        var count = scenarios.count
        for axis in axes {
            guard !axis.values.isEmpty else {
                throw DesignError.invalidStudy("Robust design axes cannot be empty")
            }
            for value in axis.values { try validate(value, for: axis.parameter) }
            let product = count.multipliedReportingOverflow(by: axis.values.count)
            guard !product.overflow, product.partialValue <= 16_384 else {
                throw DesignError.invalidStudy("Robust design exceeds 16384 analyses")
            }
            count = product.partialValue
        }
    }

    public func makeSweepJob(
        project: MeshLabProject,
        name: String? = nil
    ) throws -> SweepJob {
        try validate()
        let candidates = candidateValues()
        var requests: [SweepRequest] = []
        requests.reserveCapacity(candidates.count * scenarios.count)
        for (candidateIndex, values) in candidates.enumerated() {
            let design = try applying(values, to: project)
            for (scenarioIndex, scenario) in scenarios.enumerated() {
                let variant = try applying(scenario, to: design)
                requests.append(SweepRequest(
                    id: String(format: "robust-c%05d-s%05d", candidateIndex, scenarioIndex),
                    project: variant,
                    task: .analysis
                ))
            }
        }
        return SweepJob(name: name ?? "\(project.name) robust design", requests: requests)
    }

    public func solve(_ project: MeshLabProject) throws -> RobustDesignResult {
        let job = try makeSweepJob(project: project)
        let summaries = job.requests.map(SweepRunner.run)
        var batch = SweepBatchResult(
            name: job.name,
            elapsedSeconds: summaries.map(\.elapsedSeconds).reduce(0, +),
            summaries: summaries,
            resumedRequestCount: 0,
            executedRequestCount: summaries.count
        )
        batch.jobFingerprint = SweepRunner.jobFingerprint(job)
        batch.shardIndex = 0
        batch.shardCount = 1
        batch.artifactID = SweepRunner.artifactID(batch)
        return try reduce(batch, for: project, job: job)
    }

    public func reduce(
        _ batch: SweepBatchResult,
        for project: MeshLabProject,
        job: SweepJob? = nil
    ) throws -> RobustDesignResult {
        try validate()
        let expected = try job ?? makeSweepJob(project: project)
        guard batch.jobFingerprint == SweepRunner.jobFingerprint(expected),
              batch.summaries.count == expected.requests.count else {
            throw DesignError.invalidStudy("Robust design artifact does not match its study")
        }
        let expectedByID = Dictionary(uniqueKeysWithValues: expected.requests.map {
            ($0.id, SweepRunner.fingerprint($0))
        })
        var byID: [String: SweepSummary] = [:]
        for summary in batch.summaries {
            guard byID[summary.id] == nil,
                  summary.requestFingerprint == expectedByID[summary.id] else {
                throw DesignError.invalidStudy(
                    "Robust design artifact contains duplicate or modified scenarios"
                )
            }
            byID[summary.id] = summary
        }
        let candidates = candidateValues()
        let totalWeight = scenarios.reduce(0) { $0 + $1.weight }
        var responses: [RobustDesignCandidate] = []
        for (candidateIndex, values) in candidates.enumerated() {
            var compliance: [(Double, Double)] = []
            var displacement: [(Double, Double)] = []
            var stress: [(Double, Double)] = []
            var feasibleWeight = 0.0
            for (scenarioIndex, scenario) in scenarios.enumerated() {
                let id = String(format: "robust-c%05d-s%05d", candidateIndex, scenarioIndex)
                guard let summary = byID[id], summary.status == .succeeded,
                      let strainEnergy = summary.strainEnergy,
                      let maxDisplacement = summary.maxDisplacement,
                      let maxVonMises = summary.maxVonMises else {
                    throw DesignError.optimizationFailed("Robust scenario \(id) did not succeed")
                }
                let valuesByMetric: [ParametricObjective: Double] = [
                    .compliance: 2 * strainEnergy,
                    .maxDisplacement: maxDisplacement,
                    .maxVonMises: maxVonMises,
                ]
                compliance.append((2 * strainEnergy, scenario.weight))
                displacement.append((maxDisplacement, scenario.weight))
                stress.append((maxVonMises, scenario.weight))
                if constraints.allSatisfy({ valuesByMetric[$0.metric]! <= $0.upperBound }) {
                    feasibleWeight += scenario.weight
                }
            }
            let summaries: [ParametricObjective: RobustMetricSummary] = [
                .compliance: aggregate(compliance, totalWeight: totalWeight),
                .maxDisplacement: aggregate(displacement, totalWeight: totalWeight),
                .maxVonMises: aggregate(stress, totalWeight: totalWeight),
            ]
            let selected = summaries[objective]!
            let reliability = feasibleWeight / totalWeight
            responses.append(RobustDesignCandidate(
                index: candidateIndex,
                values: values,
                compliance: summaries[.compliance]!,
                maxDisplacement: summaries[.maxDisplacement]!,
                maxVonMises: summaries[.maxVonMises]!,
                reliability: reliability,
                robustObjective: selected.mean + variabilityWeight * selected.standardDeviation,
                isFeasible: reliability + 1e-14 >= minimumReliability
            ))
        }
        let feasible = responses.indices.filter { responses[$0].isFeasible }
        guard let bestIndex = feasible.min(by: {
            responses[$0].robustObjective < responses[$1].robustObjective
        }) else {
            throw DesignError.optimizationFailed("No robust candidate meets reliability")
        }
        let pareto = feasible.filter { candidate in
            !feasible.contains { challenger in
                challenger != candidate
                    && dominates(responses[challenger], responses[candidate])
            }
        }
        let bestProject = try applying(responses[bestIndex].values, to: project)
        let bestResult = try StaticAnalysis(options: project.makeAnalysisOptions())
            .solve(bestProject.makeModel())
        return RobustDesignResult(
            axes: axes,
            scenarios: scenarios,
            candidates: responses,
            objective: objective,
            bestIndex: bestIndex,
            paretoIndices: pareto,
            sweepResult: batch,
            bestModel: bestProject.makeModel(),
            bestResult: bestResult
        )
    }

    private func aggregate(
        _ values: [(value: Double, weight: Double)],
        totalWeight: Double
    ) -> RobustMetricSummary {
        let mean = values.reduce(0) { $0 + $1.value * $1.weight } / totalWeight
        let variance = values.reduce(0) {
            $0 + $1.weight * ($1.value - mean) * ($1.value - mean)
        } / totalWeight
        return RobustMetricSummary(
            mean: mean,
            standardDeviation: sqrt(max(0, variance)),
            worst: values.map(\.value).max() ?? 0
        )
    }

    private func dominates(
        _ first: RobustDesignCandidate,
        _ second: RobustDesignCandidate
    ) -> Bool {
        let lhs = [first.compliance.mean, first.maxDisplacement.mean, first.maxVonMises.mean]
        let rhs = [second.compliance.mean, second.maxDisplacement.mean, second.maxVonMises.mean]
        return zip(lhs, rhs).allSatisfy { $0 <= $1 }
            && zip(lhs, rhs).contains { $0 < $1 }
    }

    private func candidateValues() -> [[Double]] {
        var result: [[Double]] = []
        var current = [Double](repeating: 0, count: axes.count)
        func visit(_ axis: Int) {
            if axis == axes.count { result.append(current); return }
            for value in axes[axis].values { current[axis] = value; visit(axis + 1) }
        }
        visit(0)
        return result
    }

    private func applying(
        _ values: [Double],
        to project: MeshLabProject
    ) throws -> MeshLabProject {
        var variant = project
        for (axis, value) in zip(axes, values) {
            switch axis.parameter {
            case .youngModulus:
                variant.material = try material(variant.material, youngModulus: value)
            case .poissonRatio:
                variant.material = try ElasticMaterial(
                    youngModulus: variant.material.youngModulus,
                    poissonRatio: value,
                    density: variant.material.density,
                    planeKinematics: variant.material.planeKinematics,
                    thickness: variant.material.thickness,
                    thermalConductivity: variant.material.thermalConductivity,
                    thermalExpansion: variant.material.thermalExpansion
                )
            case .thickness:
                variant.material = try ElasticMaterial(
                    youngModulus: variant.material.youngModulus,
                    poissonRatio: variant.material.poissonRatio,
                    density: variant.material.density,
                    planeKinematics: variant.material.planeKinematics,
                    thickness: value,
                    thermalConductivity: variant.material.thermalConductivity,
                    thermalExpansion: variant.material.thermalExpansion
                )
            case .loadScale: variant.loadScale = value
            }
        }
        return variant
    }

    private func applying(
        _ scenario: DesignUncertaintyScenario,
        to project: MeshLabProject
    ) throws -> MeshLabProject {
        var variant = project
        variant.loadScale *= scenario.loadMultiplier
        variant.material = try material(
            variant.material,
            youngModulus: variant.material.youngModulus * scenario.youngModulusMultiplier
        )
        return variant
    }

    private func material(
        _ source: ElasticMaterial,
        youngModulus: Double
    ) throws -> ElasticMaterial {
        try ElasticMaterial(
            youngModulus: youngModulus,
            poissonRatio: source.poissonRatio,
            density: source.density,
            planeKinematics: source.planeKinematics,
            thickness: source.thickness,
            thermalConductivity: source.thermalConductivity,
            thermalExpansion: source.thermalExpansion
        )
    }

    private func validate(_ value: Double, for parameter: DesignParameter) throws {
        guard value.isFinite else { throw DesignError.invalidStudy("Non-finite design value") }
        switch parameter {
        case .youngModulus, .thickness:
            guard value > 0 else { throw DesignError.invalidStudy("Design value must be positive") }
        case .poissonRatio:
            guard value > -1, value < 0.5 else { throw DesignError.invalidStudy("Invalid Poisson ratio") }
        case .loadScale:
            guard value >= 0 else { throw DesignError.invalidStudy("Negative load scale") }
        }
    }
}
