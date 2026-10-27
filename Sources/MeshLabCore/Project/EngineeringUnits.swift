import Foundation

public enum EngineeringLengthUnit: String, Sendable, Hashable, Codable, CaseIterable {
    case meter
    case millimeter

    public var symbol: String {
        switch self {
        case .meter: "m"
        case .millimeter: "mm"
        }
    }

    public func displayValue(fromSolver value: Double) -> Double {
        switch self {
        case .meter: value
        case .millimeter: value * 1_000
        }
    }

    public func solverValue(fromDisplay value: Double) -> Double {
        switch self {
        case .meter: value
        case .millimeter: value / 1_000
        }
    }
}

public enum EngineeringStressUnit: String, Sendable, Hashable, Codable, CaseIterable {
    case pascal
    case megapascal

    public var symbol: String {
        switch self {
        case .pascal: "Pa"
        case .megapascal: "MPa"
        }
    }

    public func displayValue(fromSolver value: Double) -> Double {
        switch self {
        case .pascal: value
        case .megapascal: value / 1_000_000
        }
    }

    public func solverValue(fromDisplay value: Double) -> Double {
        switch self {
        case .pascal: value
        case .megapascal: value * 1_000_000
        }
    }
}

public enum EngineeringTemperatureUnit: String, Sendable, Hashable, Codable, CaseIterable {
    case kelvin
    case celsius

    public var symbol: String {
        switch self {
        case .kelvin: "K"
        case .celsius: "°C"
        }
    }

    public func displayValue(fromSolver value: Double) -> Double {
        switch self {
        case .kelvin: value
        case .celsius: value - 273.15
        }
    }

    public func solverValue(fromDisplay value: Double) -> Double {
        switch self {
        case .kelvin: value
        case .celsius: value + 273.15
        }
    }
}

/// Presentation units for engineering requirements and reports.
///
/// Analysis data and persisted requirement limits remain in solver units
/// (metres, pascals, kelvin, hertz). This value controls entry and presentation
/// only, preventing a display-unit change from altering the physical model.
public struct EngineeringUnitSystem: Sendable, Hashable, Codable {
    public var length: EngineeringLengthUnit
    public var stress: EngineeringStressUnit
    public var temperature: EngineeringTemperatureUnit

    public init(
        length: EngineeringLengthUnit = .meter,
        stress: EngineeringStressUnit = .pascal,
        temperature: EngineeringTemperatureUnit = .kelvin
    ) {
        self.length = length
        self.stress = stress
        self.temperature = temperature
    }

    public static let si = EngineeringUnitSystem()
    public static let millimeterMegapascal = EngineeringUnitSystem(
        length: .millimeter,
        stress: .megapascal,
        temperature: .celsius
    )
}
