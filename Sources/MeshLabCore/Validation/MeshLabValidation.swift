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
    public let cases: [ValidationCase]
    public let passed: Bool

    public init(cases: [ValidationCase]) {
        self.schemaVersion = 1
        self.suite = "meshlab-consolidation"
        self.numericContract = "swift-numeric-core-1.x"
        self.cases = cases
        self.passed = cases.allSatisfy(\.passed)
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }
}

public enum MeshLabValidation {
    public static func runStandardSuite() throws -> ValidationReport {
        ValidationReport(cases: [
            try operatorContractCase(),
            try assembledMatrixFreeCase(),
            try linearThermalCase(),
            try meshQualityCase(),
            try finiteStrainSmallLoadCase(),
            try constrainedDesignCase(),
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
}
