import Foundation
import simd

public struct CoupledThermoMechanicalOptions: Sendable, Hashable, Codable {
    public var maximumIterations: Int
    public var relativeTolerance: Double
    public var relaxation: Double
    /// Fractional Young's-modulus change per kelvin relative to the reference
    /// temperature. A negative value models thermal softening.
    public var youngModulusTemperatureCoefficient: Double
    public var minimumYoungModulusFactor: Double

    public init(
        maximumIterations: Int = 20,
        relativeTolerance: Double = 1e-7,
        relaxation: Double = 0.7,
        youngModulusTemperatureCoefficient: Double = 0,
        minimumYoungModulusFactor: Double = 0.05
    ) {
        self.maximumIterations = maximumIterations
        self.relativeTolerance = relativeTolerance
        self.relaxation = relaxation
        self.youngModulusTemperatureCoefficient = youngModulusTemperatureCoefficient
        self.minimumYoungModulusFactor = minimumYoungModulusFactor
    }
}

public struct CoupledIteration: Sendable {
    public let iteration: Int
    public let relativeTemperatureChange: Double
    public let relativeDisplacementChange: Double
    public let maximumTemperature: Double
    public let maximumDisplacement: Double
}

public struct CoupledThermoMechanicalResult: Sendable {
    public let thermalResult: ThermalResult
    public let staticResult: StaticResult
    public let iterations: [CoupledIteration]
    public let converged: Bool
}

public enum CoupledThermoMechanicalError: Error, Equatable, Sendable {
    case invalidOptions
    case incompatibleMeshes
    case unsupportedDimension
    case invalidTemperatureDependentMaterial
}

/// Staggered two-field coupling. Thermal conduction is solved on the relaxed
/// deformed geometry; its temperature field updates thermal strain and optional
/// temperature-dependent stiffness in the structural solve.
public struct CoupledThermoMechanicalAnalysis: Sendable {
    public var options: CoupledThermoMechanicalOptions
    public var analysisOptions: AnalysisOptions
    public var referenceTemperature: Double

    public init(
        options: CoupledThermoMechanicalOptions = CoupledThermoMechanicalOptions(),
        analysisOptions: AnalysisOptions = AnalysisOptions(),
        referenceTemperature: Double = 0
    ) {
        self.options = options
        self.analysisOptions = analysisOptions
        self.referenceTemperature = referenceTemperature
    }

    public func solve(
        thermal thermalModel: ThermalModel,
        structural structuralModel: FEMModel
    ) throws -> CoupledThermoMechanicalResult {
        guard options.maximumIterations > 0,
              options.relativeTolerance.isFinite,
              options.relativeTolerance > 0,
              options.relaxation.isFinite,
              options.relaxation > 0,
              options.relaxation <= 1,
              options.youngModulusTemperatureCoefficient.isFinite,
              options.minimumYoungModulusFactor.isFinite,
              options.minimumYoungModulusFactor > 0,
              referenceTemperature.isFinite else {
            throw CoupledThermoMechanicalError.invalidOptions
        }
        guard thermalModel.mesh == structuralModel.mesh else {
            throw CoupledThermoMechanicalError.incompatibleMeshes
        }
        guard structuralModel.mesh.dimension == 3 else {
            throw CoupledThermoMechanicalError.unsupportedDimension
        }

        let referenceMesh = structuralModel.mesh
        var relaxedDisplacements = [SIMD3<Double>](
            repeating: .zero,
            count: referenceMesh.nodes.count
        )
        var previousTemperatures = [Double](
            repeating: referenceTemperature,
            count: referenceMesh.nodes.count
        )
        var history: [CoupledIteration] = []
        var lastThermal: ThermalResult?
        var lastStatic: StaticResult?

        for iteration in 1...options.maximumIterations {
            try Task.checkCancellation()
            let deformedNodes = zip(referenceMesh.nodes, relaxedDisplacements).map(+)
            var thermal = thermalModel
            thermal.mesh = try Mesh(nodes: deformedNodes, elements: referenceMesh.elements)
            let thermalResult = try ThermalAnalysis(options: analysisOptions).solve(thermal)

            let averageTemperature = thermalResult.temperatures.reduce(0, +)
                / Double(thermalResult.temperatures.count)
            let factor = max(
                options.minimumYoungModulusFactor,
                1 + options.youngModulusTemperatureCoefficient
                    * (averageTemperature - referenceTemperature)
            )
            guard factor.isFinite else {
                throw CoupledThermoMechanicalError.invalidTemperatureDependentMaterial
            }
            var structural = structuralModel
            structural.material = try scaledMaterial(structural.material, modulusFactor: factor)
            if !structural.elementMaterials.isEmpty {
                structural.elementMaterials = try structural.elementMaterials.map {
                    try scaledMaterial($0, modulusFactor: factor)
                }
            }
            structural.temperatureChange = thermalResult.temperatures.map {
                $0 - referenceTemperature
            }
            let staticResult = try StaticAnalysis(options: analysisOptions).solve(structural)

            let temperatureChange = relativeDifference(
                thermalResult.temperatures,
                previousTemperatures
            )
            let displacementChange = relativeDifference(
                staticResult.displacements.flatMap { [$0.x, $0.y, $0.z] },
                relaxedDisplacements.flatMap { [$0.x, $0.y, $0.z] }
            )
            history.append(CoupledIteration(
                iteration: iteration,
                relativeTemperatureChange: temperatureChange,
                relativeDisplacementChange: displacementChange,
                maximumTemperature: thermalResult.maximumTemperature,
                maximumDisplacement: staticResult.maxDisplacement
            ))
            previousTemperatures = thermalResult.temperatures
            relaxedDisplacements = zip(relaxedDisplacements, staticResult.displacements).map {
                $0 + options.relaxation * ($1 - $0)
            }
            lastThermal = thermalResult
            lastStatic = staticResult

            if temperatureChange <= options.relativeTolerance,
               displacementChange <= options.relativeTolerance {
                return CoupledThermoMechanicalResult(
                    thermalResult: thermalResult,
                    staticResult: staticResult,
                    iterations: history,
                    converged: true
                )
            }
        }
        return CoupledThermoMechanicalResult(
            thermalResult: lastThermal!,
            staticResult: lastStatic!,
            iterations: history,
            converged: false
        )
    }

    private func scaledMaterial(
        _ material: ElasticMaterial,
        modulusFactor: Double
    ) throws -> ElasticMaterial {
        try ElasticMaterial(
            youngModulus: material.youngModulus * modulusFactor,
            poissonRatio: material.poissonRatio,
            density: material.density,
            planeKinematics: material.planeKinematics,
            thickness: material.thickness,
            thermalConductivity: material.thermalConductivity,
            thermalExpansion: material.thermalExpansion
        )
    }

    private func relativeDifference(_ first: [Double], _ second: [Double]) -> Double {
        let difference = zip(first, second).map(-)
        return VectorMath.norm(difference) / max(VectorMath.norm(first), 1)
    }
}
