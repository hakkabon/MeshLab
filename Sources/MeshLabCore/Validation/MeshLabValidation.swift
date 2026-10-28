import Foundation
import simd

public struct ValidationMetric: Sendable, Hashable, Codable {
    public let name: String
    public let observed: Double
    public let reference: Double
    public let absoluteTolerance: Double
    public let relativeTolerance: Double
    public let passed: Bool

    public init(
        name: String,
        observed: Double,
        reference: Double,
        absoluteTolerance: Double,
        relativeTolerance: Double = 0
    ) {
        self.name = name
        self.observed = observed
        self.reference = reference
        self.absoluteTolerance = absoluteTolerance
        self.relativeTolerance = relativeTolerance
        self.passed = abs(observed - reference)
            <= absoluteTolerance + relativeTolerance * abs(reference)
    }
}

public struct ValidationCase: Sendable, Hashable, Codable {
    public let identifier: String
    public let category: String
    public let metrics: [ValidationMetric]
    public let passed: Bool

    public init(identifier: String, category: String, metrics: [ValidationMetric]) {
        self.identifier = identifier
        self.category = category
        self.metrics = metrics
        self.passed = metrics.allSatisfy(\.passed)
    }
}

/// Deterministic, machine-readable evidence for the MeshLab/NumericCore seam.
/// Deliberately excludes timestamps and host details so reports can be diffed
/// in CI and compared across Swift-NumericCore and Rust-NumericCore releases.
public struct ValidationReport: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let suite: String
    public let numericContract: String
    public let numericStack: NumericStackProvenance
    public let cases: [ValidationCase]
    public let passed: Bool

    public init(cases: [ValidationCase]) {
        self.schemaVersion = 2
        self.suite = "meshlab-consolidation"
        self.numericStack = .current
        self.numericContract = numericStack.contract
        self.cases = cases
        self.passed = cases.allSatisfy(\.passed)
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Compares this run with a committed deterministic corpus snapshot.
    /// Case/metric drift, numerical-stack drift, and observations outside the
    /// declared metric tolerance fail closed.
    public func compare(to baseline: ValidationReport) -> ValidationBaselineComparison {
        var issues: [ValidationBaselineIssue] = []
        if suite != baseline.suite {
            issues.append(.init(path: "suite", message: "suite identifier changed"))
        }
        if numericStack != baseline.numericStack {
            issues.append(.init(
                path: "numericStack",
                message: "numerical stack or capability manifest changed"
            ))
        }
        let baselineCases = Dictionary(uniqueKeysWithValues: baseline.cases.map {
            ($0.identifier, $0)
        })
        let currentIdentifiers = Set(cases.map(\.identifier))
        let baselineIdentifiers = Set(baseline.cases.map(\.identifier))
        for identifier in baselineIdentifiers.subtracting(currentIdentifiers).sorted() {
            issues.append(.init(path: identifier, message: "validation case is missing"))
        }
        for identifier in currentIdentifiers.subtracting(baselineIdentifiers).sorted() {
            issues.append(.init(path: identifier, message: "validation case is new"))
        }
        for currentCase in cases {
            guard let baselineCase = baselineCases[currentCase.identifier] else { continue }
            let baselineMetrics = Dictionary(uniqueKeysWithValues: baselineCase.metrics.map {
                ($0.name, $0)
            })
            let currentNames = Set(currentCase.metrics.map(\.name))
            let baselineNames = Set(baselineCase.metrics.map(\.name))
            for name in baselineNames.subtracting(currentNames).sorted() {
                issues.append(.init(
                    path: "\(currentCase.identifier).\(name)",
                    message: "metric is missing"
                ))
            }
            for name in currentNames.subtracting(baselineNames).sorted() {
                issues.append(.init(
                    path: "\(currentCase.identifier).\(name)",
                    message: "metric is new"
                ))
            }
            for metric in currentCase.metrics {
                guard let expected = baselineMetrics[metric.name] else { continue }
                let tolerance = metric.absoluteTolerance
                    + metric.relativeTolerance * abs(expected.observed)
                let difference = abs(metric.observed - expected.observed)
                if !difference.isFinite || difference > tolerance {
                    issues.append(.init(
                        path: "\(currentCase.identifier).\(metric.name)",
                        message: "observation changed by \(difference), tolerance \(tolerance)"
                    ))
                }
            }
        }
        return ValidationBaselineComparison(issues: issues)
    }
}

public struct ValidationBaselineIssue: Sendable, Hashable, Codable {
    public let path: String
    public let message: String
}

public struct ValidationBaselineComparison: Sendable, Hashable, Codable {
    public let issues: [ValidationBaselineIssue]
    public var passed: Bool { issues.isEmpty }
}

public enum MeshLabValidation {
    public static func runStandardSuite() throws -> ValidationReport {
        ValidationReport(cases: [
            try operatorContractCase(),
            try elementKernelContractCase(),
            try assembledMatrixFreeCase(),
            try preparedLinearCase(),
            try linearThermalCase(),
            try meshQualityCase(),
            try finiteStrainSmallLoadCase(),
            try nonlinearProductionCase(),
            try transientMultiphysicsCase(),
            try scalableExecutionCase(),
            try constrainedDesignCase(),
            try engineeringQualificationCase(),
        ])
    }

    private static func operatorContractCase() throws -> ValidationCase {
        let contribution = try FEMElementContribution(
            degreesOfFreedom: [0, 1],
            matrix: [2, -1, -1, 2]
        )
        let linearOperator: any FEMLinearOperator = try FEMElementOperator(
            dimension: 2,
            contributions: [contribution]
        )
        let product = linearOperator.multiply([3, 5])
        return ValidationCase(
            identifier: "operator-contract-2x2",
            category: "interoperability",
            metrics: [
                ValidationMetric(name: "row-0", observed: product[0], reference: 1, absoluteTolerance: 0),
                ValidationMetric(name: "row-1", observed: product[1], reference: 7, absoluteTolerance: 0),
            ]
        )
    }

    private static func elementKernelContractCase() throws -> ValidationCase {
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
        let displacement = (0..<12).map { Double($0) * 1e-6 }
        let result = try LinearContinuumElementKernel().evaluate(
            FEMElementEvaluationRequest(
                mesh: mesh,
                elementIndex: 0,
                material: material,
                localDisplacement: displacement
            )
        )
        let maximumResidualError = (0..<12).map { row in
            let product = (0..<12).reduce(0.0) {
                $0 + result.tangent[row * 12 + $1] * displacement[$1]
            }
            return abs(product - result.internalForce[row])
        }.max() ?? 0
        return ValidationCase(
            identifier: "tet4-element-kernel-contract",
            category: "interoperability",
            metrics: [
                ValidationMetric(
                    name: "tangent-residual-consistency",
                    observed: maximumResidualError,
                    reference: 0,
                    absoluteTolerance: 1e-10
                ),
            ]
        )
    }

    private static func preparedLinearCase() throws -> ValidationCase {
        let project = try MeshLabProject.cantileverExample()
        let model = project.makeModel()
        let options = AnalysisOptions(solverMethod: .numericCoreCholesky)
        let prepared = try PreparedLinearStaticAnalysis(
            model: FEMModel(
                mesh: model.mesh,
                material: model.material,
                constraints: model.constraints
            ),
            options: options
        )
        let reused = try prepared.solve(loads: model.loads, bodyForce: model.bodyForce)
        let independent = try StaticAnalysis(options: options).solve(model)
        return ValidationCase(
            identifier: "prepared-linear-factorization-reuse",
            category: "structural",
            metrics: [
                ValidationMetric(
                    name: "maximum-displacement",
                    observed: reused.maxDisplacement,
                    reference: independent.maxDisplacement,
                    absoluteTolerance: 1e-14,
                    relativeTolerance: 1e-10
                ),
                ValidationMetric(
                    name: "preparation-count",
                    observed: Double(prepared.preparationCount),
                    reference: 1,
                    absoluteTolerance: 0
                ),
            ]
        )
    }

    private static func assembledMatrixFreeCase() throws -> ValidationCase {
        let project = try MeshLabProject.cantileverExample()
        let assembled = try StaticAnalysis(options: AnalysisOptions(
            solverMethod: .numericCoreCholesky
        )).solve(project.makeModel())
        let matrixFree = try StaticAnalysis(options: AnalysisOptions(
            matrixFreeOptions: MatrixFreeOptions(
                maximumIterations: 2_000,
                relativeTolerance: 1e-10
            )
        )).solve(project.makeModel())

        return ValidationCase(
            identifier: "cantilever-assembled-matrix-free",
            category: "structural",
            metrics: [
                ValidationMetric(
                    name: "maximum-displacement",
                    observed: matrixFree.maxDisplacement,
                    reference: assembled.maxDisplacement,
                    absoluteTolerance: 1e-14,
                    relativeTolerance: 1e-7
                ),
                ValidationMetric(
                    name: "strain-energy",
                    observed: matrixFree.strainEnergy,
                    reference: assembled.strainEnergy,
                    absoluteTolerance: 1e-14,
                    relativeTolerance: 1e-7
                ),
                ValidationMetric(
                    name: "maximum-von-mises",
                    observed: matrixFree.maxVonMises,
                    reference: assembled.maxVonMises,
                    absoluteTolerance: 1e-8,
                    relativeTolerance: 1e-7
                ),
                ValidationMetric(
                    name: "force-imbalance",
                    observed: simd_length(assembled.equilibrium.forceImbalance),
                    reference: 0,
                    absoluteTolerance: 1e-6
                ),
                ValidationMetric(
                    name: "moment-imbalance",
                    observed: simd_length(assembled.equilibrium.momentImbalance),
                    reference: 0,
                    absoluteTolerance: 1e-6
                ),
            ]
        )
    }

    private static func linearThermalCase() throws -> ValidationCase {
        let mesh = try MeshGenerators.structuredBox(
            size: SIMD3<Double>(1, 1, 4),
            divisions: SIMD3<Int>(1, 1, 8)
        )
        let material = try ElasticMaterial(
            youngModulus: 200e9,
            poissonRatio: 0.3,
            thermalConductivity: 50
        )
        let constraints = mesh.nodeIndices { abs($0.z) < 1e-12 }
            .map { ThermalConstraint(node: $0, temperature: 0) }
            + mesh.nodeIndices { abs($0.z - 4) < 1e-12 }
            .map { ThermalConstraint(node: $0, temperature: 100) }
        let result = try ThermalAnalysis(options: AnalysisOptions(
            solverMethod: .numericCoreCholesky
        )).solve(ThermalModel(
            mesh: mesh,
            material: material,
            constraints: constraints
        ))
        let maximumTemperatureError = mesh.nodes.indices.map {
            abs(result.temperatures[$0] - 25 * mesh.nodes[$0].z)
        }.max() ?? 0
        let maximumFluxError = result.elementHeatFluxes.map {
            simd_length($0.vector - SIMD3<Double>(0, 0, -1_250))
        }.max() ?? 0

        return ValidationCase(
            identifier: "linear-thermal-bar",
            category: "thermal",
            metrics: [
                ValidationMetric(
                    name: "maximum-temperature-error",
                    observed: maximumTemperatureError,
                    reference: 0,
                    absoluteTolerance: 1e-9
                ),
                ValidationMetric(
                    name: "maximum-flux-error",
                    observed: maximumFluxError,
                    reference: 0,
                    absoluteTolerance: 1e-8
                ),
            ]
        )
    }

    private static func meshQualityCase() throws -> ValidationCase {
        let mesh = try MeshGenerators.structuredBox(
            size: SIMD3<Double>(1, 1, 1),
            divisions: SIMD3<Int>(1, 1, 1)
        )
        let report = mesh.qualityReport()
        return ValidationCase(
            identifier: "structured-mesh-quality",
            category: "mesh",
            metrics: [
                ValidationMetric(
                    name: "minimum-quality",
                    observed: report.minimumQuality,
                    reference: 1 / (3 * Foundation.sqrt(3)),
                    absoluteTolerance: 1e-12
                ),
                ValidationMetric(
                    name: "inverted-elements",
                    observed: Double(report.invertedElementIndices.count),
                    reference: 0,
                    absoluteTolerance: 0
                ),
            ]
        )
    }

    private static func finiteStrainSmallLoadCase() throws -> ValidationCase {
        let mesh = try Mesh(
            nodes: [
                SIMD3<Double>(0, 0, 0),
                SIMD3<Double>(1, 0, 0),
                SIMD3<Double>(0, 1, 0),
                SIMD3<Double>(0, 0, 1),
            ],
            elements: [Element(type: .tetrahedron4, nodes: [0, 1, 2, 3])]
        )
        let material = try ElasticMaterial(youngModulus: 1e7, poissonRatio: 0.3)
        let model = FEMModel(
            mesh: mesh,
            material: material,
            constraints: [
                .fixed(node: 0),
                .fixed(node: 1, axis: 1),
                .fixed(node: 1, axis: 2),
                .fixed(node: 2, axis: 2),
            ],
            loads: [.nodal(node: 3, vector: SIMD3<Double>(0, 0, 10))]
        )
        let linear = try StaticAnalysis(options: AnalysisOptions(
            solverMethod: .numericCoreCholesky
        )).solve(model)
        let nonlinear = try NonlinearStaticAnalysis(options: NonlinearStaticOptions(
            loadSteps: 2,
            maximumNewtonIterations: 20,
            residualTolerance: 1e-10,
            stepTolerance: 1e-12
        )).solve(model).staticResult
        return ValidationCase(
            identifier: "finite-strain-small-load",
            category: "nonlinear-structural",
            metrics: [
                ValidationMetric(
                    name: "maximum-displacement",
                    observed: nonlinear.maxDisplacement,
                    reference: linear.maxDisplacement,
                    absoluteTolerance: 1e-12,
                    relativeTolerance: 1e-4
                ),
                ValidationMetric(
                    name: "relative-free-residual",
                    observed: nonlinear.equilibrium.relativeFreeResidual,
                    reference: 0,
                    absoluteTolerance: 1e-9
                ),
            ]
        )
    }

    private static func nonlinearProductionCase() throws -> ValidationCase {
        let mesh = try Mesh(
            nodes: [
                SIMD3<Double>(0, 0, 0), SIMD3<Double>(1, 0, 0),
                SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, 0, 1),
            ],
            elements: [Element(type: .tetrahedron4, nodes: [0, 1, 2, 3])]
        )
        let material = try ElasticMaterial(youngModulus: 1e7, poissonRatio: 0.3)
        func model(load: Double) -> FEMModel {
            FEMModel(
                mesh: mesh,
                material: material,
                constraints: [
                    .fixed(node: 0),
                    .fixed(node: 1, axis: 1), .fixed(node: 1, axis: 2),
                    .fixed(node: 2, axis: 2),
                ],
                loads: [.nodal(node: 3, vector: SIMD3<Double>(0, 0, load))]
            )
        }
        let smallModel = model(load: 10)
        let linear = try StaticAnalysis().solve(smallModel)
        let neoHookean = try NonlinearStaticAnalysis(options: NonlinearStaticOptions(
            loadSteps: 2,
            residualTolerance: 1e-10,
            constitutiveModel: .neoHookean
        )).solve(smallModel)
        let plastic = try NonlinearStaticAnalysis(options: NonlinearStaticOptions(
            loadSteps: 8,
            residualTolerance: 1e-8,
            constitutiveModel: .j2Plasticity,
            yieldStress: 1_000,
            hardeningModulus: 50_000
        )).solve(model(load: 2_000))
        let relativeNeoHookeanError = abs(
            neoHookean.staticResult.maxDisplacement - linear.maxDisplacement
        ) / linear.maxDisplacement
        let equivalentPlasticStrain = plastic.elementStates.first?.values.last ?? 0
        return ValidationCase(
            identifier: "nonlinear-production-contract",
            category: "nonlinear-structural",
            metrics: [
                ValidationMetric(
                    name: "neo-hookean-linear-limit",
                    observed: relativeNeoHookeanError,
                    reference: 0,
                    absoluteTolerance: 1e-4
                ),
                ValidationMetric(
                    name: "plastic-state-width",
                    observed: Double(plastic.elementStates.first?.values.count ?? 0),
                    reference: 7,
                    absoluteTolerance: 0
                ),
                ValidationMetric(
                    name: "plastic-yielded",
                    observed: equivalentPlasticStrain > 0 ? 1 : 0,
                    reference: 1,
                    absoluteTolerance: 0
                ),
                ValidationMetric(
                    name: "final-load-factor",
                    observed: plastic.loadSteps.last?.loadFactor ?? 0,
                    reference: 1,
                    absoluteTolerance: 0
                ),
            ]
        )
    }

    private static func constrainedDesignCase() throws -> ValidationCase {
        let project = try MeshLabProject.cantileverExample()
        let baseline = try StaticAnalysis(options: project.makeAnalysisOptions())
            .solve(project.makeModel())
        let result = try ParametricStudy(
            axes: [ParametricAxis(parameter: .loadScale, values: [0.5, 1, 2])],
            constraints: [ParametricConstraint(
                metric: .maxDisplacement,
                upperBound: baseline.maxDisplacement * 1.1
            )],
            paretoObjectives: [.compliance, .maxVonMises]
        ).solve(project)
        return ValidationCase(
            identifier: "constrained-parametric-pareto",
            category: "design",
            metrics: [
                ValidationMetric(
                    name: "feasible-samples",
                    observed: Double(result.feasibleSampleCount),
                    reference: 2,
                    absoluteTolerance: 0
                ),
                ValidationMetric(
                    name: "pareto-samples",
                    observed: Double(result.paretoIndices.count),
                    reference: 1,
                    absoluteTolerance: 0
                ),
                ValidationMetric(
                    name: "best-index",
                    observed: Double(result.bestIndex),
                    reference: 0,
                    absoluteTolerance: 0
                ),
            ]
        )
    }

    private static func scalableExecutionCase() throws -> ValidationCase {
        let project = try MeshLabProject.cantileverExample()
        let job = SweepJob(name: "validation-shards", requests: (0..<5).map {
            SweepRequest(id: "request-\($0)", project: project)
        })
        let shards = try (0..<3).map {
            try SweepRunner.makeShard(job, index: $0, count: 3)
        }
        let ids = shards.flatMap { $0.job.requests.map(\.id) }
        let fingerprint = SweepRunner.jobFingerprint(job)
        return ValidationCase(
            identifier: "scalable-execution-contract",
            category: "execution",
            metrics: [
                ValidationMetric(
                    name: "request-coverage",
                    observed: Double(ids.count),
                    reference: 5,
                    absoluteTolerance: 0
                ),
                ValidationMetric(
                    name: "unique-assignment",
                    observed: Double(Set(ids).count),
                    reference: 5,
                    absoluteTolerance: 0
                ),
                ValidationMetric(
                    name: "shared-job-identity",
                    observed: shards.allSatisfy { $0.jobFingerprint == fingerprint } ? 1 : 0,
                    reference: 1,
                    absoluteTolerance: 0
                ),
            ]
        )
    }

    private static func transientMultiphysicsCase() throws -> ValidationCase {
        let mesh = try MeshGenerators.structuredBox(
            size: SIMD3<Double>(1, 1, 1),
            divisions: SIMD3<Int>(1, 1, 2)
        )
        let material = try ElasticMaterial(
            youngModulus: 1e7,
            poissonRatio: 0.3,
            density: 1_000,
            thermalConductivity: 10,
            thermalExpansion: 1e-5
        )
        let constraints = mesh.nodeIndices { abs($0.z) < 1e-12 }
            .map { ThermalConstraint(node: $0, temperature: 0) }
        let initial = mesh.nodes.map { $0.z == 0 ? 0.0 : 100.0 }
        let result = try TransientThermalAnalysis(options: TransientThermalOptions(
            timeStep: 0.1,
            steps: 2,
            volumetricHeatCapacity: 100
        )).solve(
            ThermalModel(mesh: mesh, material: material, constraints: constraints),
            initialTemperature: initial
        )
        return ValidationCase(
            identifier: "transient-multiphysics-contract",
            category: "transient-multiphysics",
            metrics: [
                ValidationMetric(
                    name: "state-count",
                    observed: Double(result.states.count),
                    reference: 3,
                    absoluteTolerance: 0
                ),
                ValidationMetric(
                    name: "final-time",
                    observed: result.states.last?.time ?? 0,
                    reference: 0.2,
                    absoluteTolerance: 1e-15
                ),
                ValidationMetric(
                    name: "relative-residual",
                    observed: result.maximumRelativeResidual,
                    reference: 0,
                    absoluteTolerance: 1e-10
                ),
                ValidationMetric(
                    name: "energy-dissipated",
                    observed: result.states.last!.thermalEnergy
                        < result.states.first!.thermalEnergy ? 1 : 0,
                    reference: 1,
                    absoluteTolerance: 0
                ),
            ]
        )
    }

    private static func engineeringQualificationCase() throws -> ValidationCase {
        var project = try MeshLabProject.cantileverExample()
        project.engineeringMetadata = EngineeringProjectMetadata(
            identifier: "validation-cantilever",
            revision: "1"
        )
        project.engineeringRequirements = EngineeringRequirements(
            maximumDisplacement: 1,
            maximumVonMises: 1e12,
            maximumRelativeResidual: 1e-8,
            minimumMeshQuality: 0.01
        )
        let artifact = try EngineeringAssessment.run(project)
        return ValidationCase(
            identifier: "qualified-static-artifact",
            category: "engineering-platform",
            metrics: [
                ValidationMetric(
                    name: "passed",
                    observed: artifact.passed ? 1 : 0,
                    reference: 1,
                    absoluteTolerance: 0
                ),
                ValidationMetric(
                    name: "failed-checks",
                    observed: Double(artifact.checks.filter {
                        $0.status != .passed
                    }.count),
                    reference: 0,
                    absoluteTolerance: 0
                ),
            ]
        )
    }
}
