import Foundation
import NumericCoreOptimization
import simd

public struct TopologyOptions: Sendable {
    /// Target physical volume divided by the full mesh volume.
    public var volumeFraction: Double
    /// SIMP exponent.
    public var penalty: Double
    /// Stiffness multiplier assigned to void material.
    public var minimumStiffnessScale: Double
    /// Sensitivity-filter radius in model units. Zero disables filtering.
    public var filterRadius: Double
    public var outerIterations: Int
    public var innerIterations: Int
    public var volumeTolerance: Double
    public var initialDensities: [Double]?
    public var analysisOptions: AnalysisOptions
    public var optimizationOptions: LBFGSOptions

    public init(
        volumeFraction: Double = 0.5,
        penalty: Double = 3,
        minimumStiffnessScale: Double = 1e-3,
        filterRadius: Double = 0,
        outerIterations: Int = 4,
        innerIterations: Int = 20,
        volumeTolerance: Double = 1e-3,
        initialDensities: [Double]? = nil,
        analysisOptions: AnalysisOptions = AnalysisOptions(),
        optimizationOptions: LBFGSOptions = LBFGSOptions()
    ) {
        self.volumeFraction = volumeFraction
        self.penalty = penalty
        self.minimumStiffnessScale = minimumStiffnessScale
        self.filterRadius = filterRadius
        self.outerIterations = outerIterations
        self.innerIterations = innerIterations
        self.volumeTolerance = volumeTolerance
        self.initialDensities = initialDensities
        self.analysisOptions = analysisOptions
        self.optimizationOptions = optimizationOptions
    }
}

public struct TopologyIteration: Sendable, Hashable {
    public let iteration: Int
    public let compliance: Double
    public let volumeFraction: Double
    public let change: Double
    public let innerIterations: Int
    public let termination: NonlinearTermination
}

public struct TopologyResult: Sendable {
    public let densities: [Double]
    public let stiffnessScales: [Double]
    public let iterations: [TopologyIteration]
    public let initialCompliance: Double
    public let finalCompliance: Double
    public let volumeFraction: Double
    public let finalModel: FEMModel
    public let finalResult: StaticResult
    public let optimization: LBFGSResult
}

/// SIMP topology optimization with a density volume constraint.
///
/// The objective is compliance, the adjoint gradient is supplied by
/// ``ComplianceAdjoint``, and NumericCore's projected L-BFGS-B solves each
/// bound-constrained augmented-Lagrangian subproblem.
public struct TopologyOptimization: Sendable {
    public var options: TopologyOptions

    public init(options: TopologyOptions = TopologyOptions()) {
        self.options = options
    }

    public func solve(_ model: FEMModel) throws -> TopologyResult {
        try validate(model)
        let mesh = model.mesh
        let count = mesh.elements.count
        let densities = options.initialDensities ?? [Double](
            repeating: options.volumeFraction,
            count: count
        )
        guard densities.count == count else {
            throw DesignError.invalidStudy(
                "Initial densities must provide one value per element"
            )
        }
        for density in densities {
            guard density.isFinite,
                  density >= options.minimumDensity,
                  density <= 1 else {
                throw DesignError.invalidStudy(
                    "Initial densities must lie between the minimum density and one"
                )
            }
        }

        let volumes = try mesh.elements.indices.map {
            try ElementKinematics.compute(
                mesh: mesh,
                material: model.material,
                elementIndex: $0
            ).measure
        }
        let totalVolume = volumes.reduce(0, +)
        guard totalVolume > 0 else {
            throw DesignError.invalidStudy("Mesh volume must be positive")
        }
        let targetVolume = options.volumeFraction * totalVolume
        guard targetVolume > 0 else {
            throw DesignError.invalidStudy("Target volume must be positive")
        }

        let neighbors = makeNeighbors(mesh: mesh, radius: options.filterRadius)
        let initial = try evaluate(
            model,
            densities: densities,
            volumes: volumes,
            neighbors: neighbors
        )
        guard initial.compliance > 0 else {
            throw DesignError.invalidStudy(
                "Topology optimization requires a non-zero compliance response"
            )
        }

        var design = densities
        var lambda = 0.0
        var mu = 10.0
        var history: [TopologyIteration] = []
        var lastOptimization: LBFGSResult?
        var lastEvaluation = initial

        for outer in 1...options.outerIterations {
            try Task.checkCancellation()
            let previous = design
            let currentLambda = lambda
            let currentMu = mu
            var innerOptions = options.optimizationOptions
            innerOptions.maxIterations = options.innerIterations

            let optimization: LBFGSResult
            do {
                optimization = try LBFGSB.minimize(
                    initial: design,
                    bounds: [ParameterBound](
                        repeating: ParameterBound(
                            lower: options.minimumDensity,
                            upper: 1
                        ),
                        count: count
                    ),
                    options: innerOptions
                ) { candidate in
                    let evaluation = try evaluate(
                        model,
                        densities: candidate,
                        volumes: volumes,
                        neighbors: neighbors
                    )
                    let constraint = evaluation.volume / targetVolume - 1
                    let value = evaluation.compliance / initial.compliance
                        + currentLambda * constraint
                        + 0.5 * currentMu * constraint * constraint
                    var gradient = evaluation.densityGradient.map {
                        $0 / initial.compliance
                    }
                    let penalty = (currentLambda + currentMu * constraint)
                        / targetVolume
                    for index in gradient.indices {
                        gradient[index] += penalty * volumes[index]
                    }
                    return (value, gradient)
                }
            } catch {
                throw DesignError.optimizationFailed(String(describing: error))
            }

            design = optimization.point
            lastOptimization = optimization
            let evaluation = try evaluate(
                model,
                densities: design,
                volumes: volumes,
                neighbors: neighbors
            )
            lastEvaluation = evaluation
            let constraint = evaluation.volume / targetVolume - 1
            let change = zip(design, previous).map { abs($0 - $1) }.max() ?? 0
            history.append(TopologyIteration(
                iteration: outer,
                compliance: evaluation.compliance,
                volumeFraction: evaluation.volume / totalVolume,
                change: change,
                innerIterations: optimization.iterations,
                termination: optimization.termination
            ))

            lambda += mu * constraint
            if abs(constraint) <= options.volumeTolerance {
                break
            }
            mu = min(mu * 4, 1e6)
        }

        guard let optimization = lastOptimization else {
            throw DesignError.optimizationFailed("Topology optimization did not run")
        }
        let finalEvaluation = lastEvaluation
        let scales = design.map { scale(for: $0) }
        var finalModel = model
        finalModel.elementStiffnessScales = scales
        let finalResult = try StaticAnalysis(options: options.analysisOptions)
            .solve(finalModel)

        return TopologyResult(
            densities: design,
            stiffnessScales: scales,
            iterations: history,
            initialCompliance: initial.compliance,
            finalCompliance: finalEvaluation.compliance,
            volumeFraction: finalEvaluation.volume / totalVolume,
            finalModel: finalModel,
            finalResult: finalResult,
            optimization: optimization
        )
    }

    private struct Evaluation {
        let compliance: Double
        let densityGradient: [Double]
        let volume: Double
    }

    private func evaluate(
        _ base: FEMModel,
        densities: [Double],
        volumes: [Double],
        neighbors: [[(index: Int, weight: Double)]]
    ) throws -> Evaluation {
        try Task.checkCancellation()
        var model = base
        model.elementStiffnessScales = densities.map { scale(for: $0) }
        let sensitivity = try ComplianceAdjoint.solve(
            model,
            options: options.analysisOptions
        )

        var gradient = [Double](repeating: 0, count: densities.count)
        for index in densities.indices {
            let density = max(densities[index], options.minimumDensity)
            let derivative = options.penalty
                * (1 - options.minimumStiffnessScale)
                * pow(density, options.penalty - 1)
            gradient[index] = sensitivity.elementStiffnessGradient[index] * derivative
        }
        if !neighbors.isEmpty {
            gradient = filter(
                gradient,
                densities: densities,
                neighbors: neighbors
            )
        }
        let volume = zip(densities, volumes).reduce(0) { $0 + $1.0 * $1.1 }
        return Evaluation(
            compliance: sensitivity.compliance,
            densityGradient: gradient,
            volume: volume
        )
    }

    private func scale(for density: Double) -> Double {
        options.minimumStiffnessScale
            + (1 - options.minimumStiffnessScale)
            * pow(max(density, 0), options.penalty)
    }

    private func filter(
        _ gradient: [Double],
        densities: [Double],
        neighbors: [[(index: Int, weight: Double)]]
    ) -> [Double] {
        gradient.indices.map { index in
            var numerator = 0.0
            var denominator = 0.0
            for neighbor in neighbors[index] {
                numerator += neighbor.weight
                    * densities[neighbor.index]
                    * gradient[neighbor.index]
                denominator += neighbor.weight
            }
            let scale = max(densities[index], options.minimumDensity) * denominator
            return scale > 0 ? numerator / scale : 0
        }
    }

    private func makeNeighbors(
        mesh: Mesh,
        radius: Double
    ) -> [[(index: Int, weight: Double)]] {
        guard radius > 0 else { return [] }
        let centers = mesh.elements.indices.map { index -> SIMD3<Double> in
            let nodes = mesh.elements[index].nodes
            return nodes.reduce(SIMD3<Double>.zero) {
                $0 + mesh.nodes[$1]
            } / Double(nodes.count)
        }
        return centers.indices.map { first in
            centers.indices.compactMap { second in
                let distance = simd_distance(centers[first], centers[second])
                guard distance <= radius else { return nil }
                return (second, radius - distance)
            }
        }
    }

    private func validate(_ model: FEMModel) throws {
        guard !model.mesh.elements.isEmpty else {
            throw DesignError.invalidStudy("Topology optimization needs a mesh")
        }
        guard !model.constraints.isEmpty,
              model.constraints.allSatisfy({ $0.value == 0 }) else {
            throw DesignError.invalidStudy(
                "Topology optimization requires homogeneous Dirichlet constraints"
            )
        }
        guard model.temperatureChange.isEmpty else {
            throw DesignError.invalidStudy(
                "Topology optimization does not include thermal loading"
            )
        }
        guard options.volumeFraction.isFinite,
              options.volumeFraction > 0,
              options.volumeFraction <= 1 else {
            throw DesignError.invalidStudy(
                "Volume fraction must lie between zero and one"
            )
        }
        guard options.penalty.isFinite, options.penalty > 1 else {
            throw DesignError.invalidStudy("SIMP penalty must be greater than one")
        }
        guard options.minimumStiffnessScale.isFinite,
              options.minimumStiffnessScale > 0,
              options.minimumStiffnessScale < 1 else {
            throw DesignError.invalidStudy(
                "Minimum stiffness scale must lie between zero and one"
            )
        }
        guard options.filterRadius.isFinite, options.filterRadius >= 0 else {
            throw DesignError.invalidStudy("Filter radius must be non-negative")
        }
        guard options.outerIterations > 0, options.innerIterations > 0 else {
            throw DesignError.invalidStudy("Optimization iteration counts must be positive")
        }
        guard options.volumeTolerance.isFinite, options.volumeTolerance > 0 else {
            throw DesignError.invalidStudy("Volume tolerance must be positive")
        }
        try (model.mesh.elements.indices).forEach {
            _ = try model.stiffnessScale(forElement: $0)
        }
    }
}

private extension TopologyOptions {
    var minimumDensity: Double { 1e-3 }
}
