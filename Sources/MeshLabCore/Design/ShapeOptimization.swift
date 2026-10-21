import Foundation
import NumericCoreOptimization
import simd

public struct ShapeDesignVariable: Sendable, Hashable, Codable {
    public var node: Int
    public var axis: Int
    public var lower: Double
    public var upper: Double

    public init(
        node: Int,
        axis: Int,
        lower: Double,
        upper: Double
    ) {
        self.node = node
        self.axis = axis
        self.lower = lower
        self.upper = upper
    }
}

public struct ShapeOptions: Sendable {
    public var volumeTargetRatio: Double
    public var outerIterations: Int
    public var innerIterations: Int
    public var volumeTolerance: Double
    public var finiteDifferenceStep: Double
    public var analysisOptions: AnalysisOptions
    public var optimizationOptions: LBFGSOptions

    public init(
        volumeTargetRatio: Double = 1,
        outerIterations: Int = 4,
        innerIterations: Int = 12,
        volumeTolerance: Double = 1e-3,
        finiteDifferenceStep: Double = 1e-6,
        analysisOptions: AnalysisOptions = AnalysisOptions(),
        optimizationOptions: LBFGSOptions = LBFGSOptions()
    ) {
        self.volumeTargetRatio = volumeTargetRatio
        self.outerIterations = outerIterations
        self.innerIterations = innerIterations
        self.volumeTolerance = volumeTolerance
        self.finiteDifferenceStep = finiteDifferenceStep
        self.analysisOptions = analysisOptions
        self.optimizationOptions = optimizationOptions
    }
}

public struct ShapeIteration: Sendable, Hashable {
    public let iteration: Int
    public let compliance: Double
    public let volumeFraction: Double
    public let change: Double
    public let innerIterations: Int
    public let termination: NonlinearTermination
}

public struct ShapeSensitivity: Sendable {
    public let compliance: Double
    public let volume: Double
    public let complianceGradient: [Double]
    public let volumeGradient: [Double]
}

public struct ShapeResult: Sendable {
    public let variables: [ShapeDesignVariable]
    public let design: [Double]
    public let mesh: Mesh
    public let model: FEMModel
    public let staticResult: StaticResult
    public let iterations: [ShapeIteration]
    public let initialCompliance: Double
    public let finalCompliance: Double
    public let volumeFraction: Double
    public let optimization: LBFGSResult
}

/// Bound-constrained node-motion shape optimization for static compliance.
///
/// The compliance derivative uses the discrete self-adjoint relation
/// `dC = 2uᵀdf - uᵀdKu`. Element stiffness and load derivatives are evaluated
/// with central differences of the assembled matrices, so no additional finite
/// element solves are needed for the gradient. A volume equality constraint is
/// handled by an augmented Lagrangian around NumericCore's L-BFGS-B.
public struct ShapeOptimization: Sendable {
    public var options: ShapeOptions

    public init(options: ShapeOptions = ShapeOptions()) {
        self.options = options
    }

    /// Evaluates the discrete shape sensitivity at the current coordinates.
    public func sensitivity(
        _ model: FEMModel,
        variables: [ShapeDesignVariable]
    ) throws -> ShapeSensitivity {
        try validate(model, variables: variables)
        let design = variables.map {
            model.mesh.nodes[$0.node][$0.axis]
        }
        let evaluation = try evaluate(
            model,
            variables: variables,
            design: design,
            needGradient: true
        )
        return ShapeSensitivity(
            compliance: evaluation.compliance,
            volume: evaluation.volume,
            complianceGradient: evaluation.complianceGradient,
            volumeGradient: evaluation.volumeGradient
        )
    }

    public func solve(
        _ model: FEMModel,
        variables: [ShapeDesignVariable]
    ) throws -> ShapeResult {
        try validate(model, variables: variables)
        var design = variables.map { variable in
            model.mesh.nodes[variable.node][variable.axis]
        }
        let initial = try evaluate(
            model,
            variables: variables,
            design: design,
            needGradient: false
        )
        guard initial.compliance > 0 else {
            throw DesignError.invalidStudy(
                "Shape optimization requires a non-zero compliance response"
            )
        }
        let initialVolume = initial.volume
        let targetVolume = options.volumeTargetRatio * initialVolume
        guard targetVolume > 0 else {
            throw DesignError.invalidStudy("Target volume must be positive")
        }

        var lambda = 0.0
        var mu = 10.0
        var history: [ShapeIteration] = []
        var lastOptimization: LBFGSResult?
        var final = initial

        for outer in 1...options.outerIterations {
            let previous = design
            let currentLambda = lambda
            let currentMu = mu
            var innerOptions = options.optimizationOptions
            innerOptions.maxIterations = options.innerIterations

            let optimization: LBFGSResult
            do {
                optimization = try LBFGSB.minimize(
                    initial: design,
                    bounds: variables.map {
                        ParameterBound(lower: $0.lower, upper: $0.upper)
                    },
                    options: innerOptions
                ) { candidate in
                    let evaluation = try evaluate(
                        model,
                        variables: variables,
                        design: candidate,
                        needGradient: true
                    )
                    let constraint = evaluation.volume / targetVolume - 1
                    let value = evaluation.compliance / initial.compliance
                        + currentLambda * constraint
                        + 0.5 * currentMu * constraint * constraint
                    var gradient = evaluation.complianceGradient.map {
                        $0 / initial.compliance
                    }
                    let penalty = (currentLambda + currentMu * constraint)
                        / targetVolume
                    for index in gradient.indices {
                        gradient[index] += penalty
                            * evaluation.volumeGradient[index]
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
                variables: variables,
                design: design,
                needGradient: false
            )
            final = evaluation
            let constraint = evaluation.volume / targetVolume - 1
            let change = zip(design, previous).map { abs($0 - $1) }.max() ?? 0
            history.append(ShapeIteration(
                iteration: outer,
                compliance: evaluation.compliance,
                volumeFraction: evaluation.volume / initialVolume,
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
            throw DesignError.optimizationFailed("Shape optimization did not run")
        }
        return ShapeResult(
            variables: variables,
            design: design,
            mesh: final.model.mesh,
            model: final.model,
            staticResult: final.result,
            iterations: history,
            initialCompliance: initial.compliance,
            finalCompliance: final.compliance,
            volumeFraction: final.volume / initialVolume,
            optimization: optimization
        )
    }

    private struct Evaluation {
        let model: FEMModel
        let result: StaticResult
        let compliance: Double
        let volume: Double
        let complianceGradient: [Double]
        let volumeGradient: [Double]
    }

    private func evaluate(
        _ base: FEMModel,
        variables: [ShapeDesignVariable],
        design: [Double],
        needGradient: Bool
    ) throws -> Evaluation {
        let model = try modelWithDesign(base, variables: variables, design: design)
        let result = try StaticAnalysis(options: options.analysisOptions).solve(model)
        let compliance = 2 * result.strainEnergy
        let volume = model.mesh.measure
        guard needGradient else {
            return Evaluation(
                model: model,
                result: result,
                compliance: compliance,
                volume: volume,
                complianceGradient: [],
                volumeGradient: []
            )
        }

        let full = fullVector(result, dimension: model.mesh.dimension)
        var complianceGradient = [Double](repeating: 0, count: variables.count)
        var volumeGradient = [Double](repeating: 0, count: variables.count)
        for index in variables.indices {
            let step = options.finiteDifferenceStep
                * max(1, abs(design[index]))
            var plusDesign = design
            var minusDesign = design
            plusDesign[index] += step
            minusDesign[index] -= step
            let plus = try modelWithDesign(
                base,
                variables: variables,
                design: plusDesign
            )
            let minus = try modelWithDesign(
                base,
                variables: variables,
                design: minusDesign
            )
            let plusStiffness = try FEMAssembly.assembleStiffness(plus).matrix
            let minusStiffness = try FEMAssembly.assembleStiffness(minus).matrix
            let plusLoads = try FEMAssembly.loadVector(plus)
            let minusLoads = try FEMAssembly.loadVector(minus)
            let plusProduct = plusStiffness.multiply(full)
            let minusProduct = minusStiffness.multiply(full)
            let dQuadratic = VectorMath.dot(
                full,
                zip(plusProduct, minusProduct).map { $0 - $1 }
            ) / (2 * step)
            let dLoad = VectorMath.dot(
                full,
                zip(plusLoads, minusLoads).map { $0 - $1 }
            ) / (2 * step)
            complianceGradient[index] = 2 * dLoad - dQuadratic
            volumeGradient[index] = (plus.mesh.measure - minus.mesh.measure)
                / (2 * step)
        }
        return Evaluation(
            model: model,
            result: result,
            compliance: compliance,
            volume: volume,
            complianceGradient: complianceGradient,
            volumeGradient: volumeGradient
        )
    }

    private func modelWithDesign(
        _ base: FEMModel,
        variables: [ShapeDesignVariable],
        design: [Double]
    ) throws -> FEMModel {
        var nodes = base.mesh.nodes
        for (variable, value) in zip(variables, design) {
            nodes[variable.node][variable.axis] = value
        }
        let mesh: Mesh
        do {
            mesh = try Mesh(nodes: nodes, elements: base.mesh.elements)
        } catch {
            throw DesignError.invalidMesh(
                "Shape trial produced an invalid mesh: \(error)"
            )
        }
        var model = base
        model.mesh = mesh
        return model
    }

    private func fullVector(
        _ result: StaticResult,
        dimension: Int
    ) -> [Double] {
        var full = [Double](repeating: 0, count: result.displacements.count * dimension)
        for (node, displacement) in result.displacements.enumerated() {
            let base = node * dimension
            full[base] = displacement.x
            if dimension > 1 { full[base + 1] = displacement.y }
            if dimension > 2 { full[base + 2] = displacement.z }
        }
        return full
    }

    private func validate(
        _ model: FEMModel,
        variables: [ShapeDesignVariable]
    ) throws {
        guard !variables.isEmpty else {
            throw DesignError.invalidStudy("Shape optimization needs design variables")
        }
        guard !model.constraints.isEmpty,
              model.constraints.allSatisfy({ $0.value == 0 }) else {
            throw DesignError.invalidStudy(
                "Shape optimization requires homogeneous Dirichlet constraints"
            )
        }
        guard model.temperatureChange.isEmpty else {
            throw DesignError.invalidStudy(
                "Shape optimization does not include thermal loading"
            )
        }
        guard options.volumeTargetRatio.isFinite,
              options.volumeTargetRatio > 0 else {
            throw DesignError.invalidStudy("Volume target ratio must be positive")
        }
        guard options.finiteDifferenceStep.isFinite,
              options.finiteDifferenceStep > 0 else {
            throw DesignError.invalidStudy(
                "Finite-difference step must be positive"
            )
        }
        guard options.outerIterations > 0, options.innerIterations > 0 else {
            throw DesignError.invalidStudy("Optimization iteration counts must be positive")
        }
        guard options.volumeTolerance.isFinite, options.volumeTolerance > 0 else {
            throw DesignError.invalidStudy("Volume tolerance must be positive")
        }

        var seen = Set<String>()
        for variable in variables {
            guard model.mesh.nodes.indices.contains(variable.node) else {
                throw DesignError.invalidVariable("Shape variable node is out of range")
            }
            guard (0..<model.mesh.dimension).contains(variable.axis) else {
                throw DesignError.invalidVariable("Shape variable axis is out of range")
            }
            guard variable.lower.isFinite, variable.upper.isFinite,
                  variable.lower < variable.upper else {
                throw DesignError.invalidVariable(
                    "Shape variable bounds must be finite and ordered"
                )
            }
            let key = "\(variable.node):\(variable.axis)"
            guard seen.insert(key).inserted else {
                throw DesignError.invalidVariable(
                    "Shape variables must be unique"
                )
            }
            let coordinate = model.mesh.nodes[variable.node][variable.axis]
            guard coordinate >= variable.lower, coordinate <= variable.upper else {
                throw DesignError.invalidVariable(
                    "Shape variable bounds must contain the current coordinate"
                )
            }
        }
    }
}
