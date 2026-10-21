import Foundation

public enum DesignError: Error, Equatable, Sendable {
    case invalidStudy(String)
    case invalidVariable(String)
    case invalidMesh(String)
    case optimizationFailed(String)
}

extension DesignError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidStudy(let message),
             .invalidVariable(let message),
             .invalidMesh(let message),
             .optimizationFailed(let message):
            return message
        }
    }
}

public enum DesignParameter: String, Sendable, Hashable, Codable, CaseIterable {
    case youngModulus
    case poissonRatio
    case thickness
    case loadScale
}

public enum ParametricObjective: String, Sendable, Hashable, Codable, CaseIterable {
    case compliance
    case maxDisplacement
    case maxVonMises
}
