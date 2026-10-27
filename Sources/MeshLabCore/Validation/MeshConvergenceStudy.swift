import Foundation

public enum MeshConvergenceResponse: String, Sendable, Hashable, Codable, CaseIterable {
    case maximumDisplacement
    case strainEnergy
    case maximumVonMises
}

public struct MeshConvergenceSample: Sendable, Hashable, Codable {
    public let characteristicSize: Double
    public let elementCount: Int
    public let response: Double

    public init(characteristicSize: Double, elementCount: Int, response: Double) {
        self.characteristicSize = characteristicSize
        self.elementCount = elementCount
        self.response = response
    }
}

public struct MeshConvergenceResult: Sendable, Hashable, Codable {
    /// Samples ordered from coarse to fine.
    public let samples: [MeshConvergenceSample]
    public let observedOrder: Double?
    public let richardsonExtrapolation: Double?
    public let estimatedRelativeError: Double?
}

public enum MeshConvergenceError: Error, Equatable, Sendable {
    case requiresThreeLevels
    case inconsistentModels
    case nonMonotonicRefinement
}

/// Runs the same static response over at least three successively refined
/// models and estimates the asymptotic order and Richardson limit.
public enum MeshConvergenceStudy {
    public static func run(
        models: [FEMModel],
        response: MeshConvergenceResponse,
        analysis: StaticAnalysis = StaticAnalysis()
    ) throws -> MeshConvergenceResult {
        guard models.count >= 3 else { throw MeshConvergenceError.requiresThreeLevels }
        let samples = try models.map { model -> MeshConvergenceSample in
            let result = try analysis.solve(model)
            let value: Double = switch response {
            case .maximumDisplacement: result.maxDisplacement
            case .strainEnergy: result.strainEnergy
            case .maximumVonMises: result.maxVonMises
            }
            let h = pow(
                model.mesh.measure / Double(model.mesh.elementCount),
                1 / Double(model.mesh.dimension)
            )
            return MeshConvergenceSample(
                characteristicSize: h,
                elementCount: model.mesh.elementCount,
                response: value
            )
        }.sorted { $0.characteristicSize > $1.characteristicSize }
        return try evaluate(samples: samples)
    }

    public static func evaluate(
        samples: [MeshConvergenceSample]
    ) throws -> MeshConvergenceResult {
        guard samples.count >= 3 else { throw MeshConvergenceError.requiresThreeLevels }
        guard samples.allSatisfy({
            $0.characteristicSize.isFinite && $0.characteristicSize > 0
                && $0.response.isFinite && $0.elementCount > 0
        }) else { throw MeshConvergenceError.inconsistentModels }
        let ordered = samples.sorted { $0.characteristicSize > $1.characteristicSize }
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ pair in
            pair.0.characteristicSize > pair.1.characteristicSize
        }) else {
            throw MeshConvergenceError.nonMonotonicRefinement
        }

        let coarse = ordered[ordered.count - 3]
        let medium = ordered[ordered.count - 2]
        let fine = ordered[ordered.count - 1]
        let firstRatio = coarse.characteristicSize / medium.characteristicSize
        let secondRatio = medium.characteristicSize / fine.characteristicSize
        let numerator = abs(coarse.response - medium.response)
        let denominator = abs(medium.response - fine.response)
        guard numerator > 0, denominator > 0,
              abs(firstRatio - secondRatio) <= 0.05 * max(firstRatio, secondRatio) else {
            return MeshConvergenceResult(
                samples: ordered,
                observedOrder: nil,
                richardsonExtrapolation: nil,
                estimatedRelativeError: nil
            )
        }
        let ratio = sqrt(firstRatio * secondRatio)
        let order = log(numerator / denominator) / log(ratio)
        guard order.isFinite, order > 0 else {
            return MeshConvergenceResult(
                samples: ordered,
                observedOrder: nil,
                richardsonExtrapolation: nil,
                estimatedRelativeError: nil
            )
        }
        let divisor = pow(secondRatio, order) - 1
        guard abs(divisor) > 1e-14 else {
            return MeshConvergenceResult(
                samples: ordered,
                observedOrder: order,
                richardsonExtrapolation: nil,
                estimatedRelativeError: nil
            )
        }
        let extrapolated = fine.response + (fine.response - medium.response) / divisor
        let error = abs(extrapolated - fine.response) / max(abs(extrapolated), 1e-30)
        return MeshConvergenceResult(
            samples: ordered,
            observedOrder: order,
            richardsonExtrapolation: extrapolated,
            estimatedRelativeError: error
        )
    }
}
