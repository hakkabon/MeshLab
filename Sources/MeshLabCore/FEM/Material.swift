import Foundation

public enum PlaneKinematics: String, Sendable, Hashable {
    case planeStress
    case planeStrain
}

public enum MaterialError: Error, Equatable, Sendable {
    case invalidYoungModulus
    case invalidPoissonRatio
    case invalidDensity
}

/// Isotropic linear elastic material.
public struct ElasticMaterial: Sendable, Hashable {
    public var youngModulus: Double
    public var poissonRatio: Double
    public var density: Double
    public var planeKinematics: PlaneKinematics
    public var thickness: Double

    public init(
        youngModulus: Double,
        poissonRatio: Double,
        density: Double = 0,
        planeKinematics: PlaneKinematics = .planeStress,
        thickness: Double = 1
    ) throws {
        guard youngModulus.isFinite, youngModulus > 0 else {
            throw MaterialError.invalidYoungModulus
        }
        guard poissonRatio.isFinite, poissonRatio > -1, poissonRatio < 0.5 else {
            throw MaterialError.invalidPoissonRatio
        }
        guard density.isFinite, density >= 0 else {
            throw MaterialError.invalidDensity
        }
        guard thickness.isFinite, thickness > 0 else {
            throw MaterialError.invalidDensity
        }
        self.youngModulus = youngModulus
        self.poissonRatio = poissonRatio
        self.density = density
        self.planeKinematics = planeKinematics
        self.thickness = thickness
    }

    public var shearModulus: Double {
        youngModulus / (2 * (1 + poissonRatio))
    }

    public var lameLambda: Double {
        youngModulus * poissonRatio / ((1 + poissonRatio) * (1 - 2 * poissonRatio))
    }

    public var bulkModulus: Double {
        youngModulus / (3 * (1 - 2 * poissonRatio))
    }

    /// Row-major constitutive matrix: 6×6 for three dimensions and 3×3 for
    /// plane stress/strain.
    public func constitutiveMatrix(for dimension: Int) -> [Double] {
        switch dimension {
        case 3:
            let lambda = lameLambda
            let mu = shearModulus
            let diagonal = lambda + 2 * mu
            return [
                diagonal, lambda, lambda, 0, 0, 0,
                lambda, diagonal, lambda, 0, 0, 0,
                lambda, lambda, diagonal, 0, 0, 0,
                0, 0, 0, mu, 0, 0,
                0, 0, 0, 0, mu, 0,
                0, 0, 0, 0, 0, mu,
            ]
        case 2:
            let e = youngModulus
            let nu = poissonRatio
            switch planeKinematics {
            case .planeStress:
                let factor = e / (1 - nu * nu)
                return [
                    factor, factor * nu, 0,
                    factor * nu, factor, 0,
                    0, 0, factor * (1 - nu) / 2,
                ]
            case .planeStrain:
                let factor = e / ((1 + nu) * (1 - 2 * nu))
                return [
                    factor * (1 - nu), factor * nu, 0,
                    factor * nu, factor * (1 - nu), 0,
                    0, 0, factor * (1 - 2 * nu) / 2,
                ]
            }
        default:
            return []
        }
    }

    /// Out-of-plane stress for plane strain: σzz = λ(εxx + εyy).
    public func outOfPlaneStress(strain: [Double]) -> Double {
        switch planeKinematics {
        case .planeStress:
            return 0
        case .planeStrain:
            return lameLambda * (strain[0] + strain[1])
        }
    }
}
