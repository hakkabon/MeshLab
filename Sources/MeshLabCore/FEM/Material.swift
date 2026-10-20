import Foundation

public enum PlaneKinematics: String, Sendable, Hashable, Codable {
    case planeStress
    case planeStrain
}

public enum MaterialError: Error, Equatable, Sendable {
    case invalidYoungModulus
    case invalidPoissonRatio
    case invalidDensity
    case invalidThermalConductivity
    case invalidThermalExpansion
}

/// Isotropic linear elastic material with optional thermal properties.
public struct ElasticMaterial: Sendable, Hashable, Codable {
    public var youngModulus: Double
    public var poissonRatio: Double
    public var density: Double
    public var planeKinematics: PlaneKinematics
    public var thickness: Double
    /// Isotropic thermal conductivity in W/(m·K). Zero disables conduction.
    public var thermalConductivity: Double
    /// Isotropic coefficient of thermal expansion in 1/K.
    public var thermalExpansion: Double

    public init(
        youngModulus: Double,
        poissonRatio: Double,
        density: Double = 0,
        planeKinematics: PlaneKinematics = .planeStress,
        thickness: Double = 1,
        thermalConductivity: Double = 0,
        thermalExpansion: Double = 0
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
        guard thermalConductivity.isFinite, thermalConductivity >= 0 else {
            throw MaterialError.invalidThermalConductivity
        }
        guard thermalExpansion.isFinite, thermalExpansion >= 0 else {
            throw MaterialError.invalidThermalExpansion
        }
        self.youngModulus = youngModulus
        self.poissonRatio = poissonRatio
        self.density = density
        self.planeKinematics = planeKinematics
        self.thickness = thickness
        self.thermalConductivity = thermalConductivity
        self.thermalExpansion = thermalExpansion
    }

    private enum CodingKeys: String, CodingKey {
        case youngModulus
        case poissonRatio
        case density
        case planeKinematics
        case thickness
        case thermalConductivity
        case thermalExpansion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            youngModulus: container.decode(Double.self, forKey: .youngModulus),
            poissonRatio: container.decode(Double.self, forKey: .poissonRatio),
            density: container.decode(Double.self, forKey: .density),
            planeKinematics: container.decode(PlaneKinematics.self, forKey: .planeKinematics),
            thickness: container.decode(Double.self, forKey: .thickness),
            thermalConductivity: container.decodeIfPresent(
                Double.self,
                forKey: .thermalConductivity
            ) ?? 0,
            thermalExpansion: container.decodeIfPresent(
                Double.self,
                forKey: .thermalExpansion
            ) ?? 0
        )
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
