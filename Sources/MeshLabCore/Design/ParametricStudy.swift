import Foundation
import simd

public struct ParametricAxis: Sendable, Hashable, Codable {
    public var parameter: DesignParameter
    public var values: [Double]

    public init(parameter: DesignParameter, values: [Double]) {
        self.parameter = parameter
        self.values = values
    }
}

public struct ParametricSample: Sendable {
    public let index: Int
    public let values: [Double]
    public let compliance: Double
    public let maxDisplacement: Double
    public let maxVonMises: Double
    public let strainEnergy: Double
}

public struct ParametricResult: Sendable {
    public let axes: [ParametricAxis]
    public let samples: [ParametricSample]
    public let objective: ParametricObjective
    public let bestIndex: Int
    /// The model and solved field of the best sample, ready for review.
    public let bestModel: FEMModel
    public let bestResult: StaticResult

    public var best: ParametricSample? {
        samples.indices.contains(bestIndex) ? samples[bestIndex] : nil
    }

    public func value(of parameter: DesignParameter, in sample: ParametricSample) -> Double? {
        guard let axis = axes.firstIndex(where: { $0.parameter == parameter }),
              sample.values.indices.contains(axis) else { return nil }
        return sample.values[axis]
    }
}

/// Cartesian sweep of editable project parameters with a static solve at every
/// point. This is the exploration half of the design loop; the optimization
/// studies below refine the best regions.
public struct ParametricStudy: Sendable, Hashable, Codable {
    public var axes: [ParametricAxis]
    public var objective: ParametricObjective

    public init(
        axes: [ParametricAxis],
        objective: ParametricObjective = .compliance
    ) {
        self.axes = axes
        self.objective = objective
    }

    public func validate() throws {
        guard !axes.isEmpty else {
            throw DesignError.invalidStudy("A parametric study needs at least one axis")
        }
        var combinations = 1
        for axis in axes {
            guard !axis.values.isEmpty else {
                throw DesignError.invalidStudy("Parametric axes cannot be empty")
            }
            for value in axis.values {
                try Self.validate(value, for: axis.parameter)
            }
            let (product, overflow) = combinations.multipliedReportingOverflow(
                by: axis.values.count
            )
            guard !overflow, product <= 4_096 else {
                throw DesignError.invalidStudy(
                    "Parametric study exceeds the 4096-sample limit"
                )
            }
            combinations = product
        }
    }

    public func solve(
        _ project: MeshLabProject,
        options: AnalysisOptions? = nil
    ) throws -> ParametricResult {
        try validate()
        let analysisOptions = options ?? project.makeAnalysisOptions()
        var samples: [ParametricSample] = []
        samples.reserveCapacity(axes.reduce(1) { $0 * $1.values.count })

        var indices = [Int](repeating: 0, count: axes.count)
        var sampleIndex = 0
        while true {
            try Task.checkCancellation()
            let values = zip(axes, indices).map { axis, index in
                axis.values[index]
            }
            let variant = try applying(values, to: project)
            let result = try StaticAnalysis(options: analysisOptions)
                .solve(variant.makeModel())
            samples.append(ParametricSample(
                index: sampleIndex,
                values: values,
                compliance: 2 * result.strainEnergy,
                maxDisplacement: result.maxDisplacement,
                maxVonMises: result.maxVonMises,
                strainEnergy: result.strainEnergy
            ))
            sampleIndex += 1

            var axis = axes.count - 1
            while axis >= 0 {
                indices[axis] += 1
                if indices[axis] < axes[axis].values.count { break }
                indices[axis] = 0
                axis -= 1
            }
            if axis < 0 { break }
        }

        let bestIndex = samples.indices.min {
            objectiveValue(samples[$0]) < objectiveValue(samples[$1])
        } ?? 0
        let bestVariant = try applying(samples[bestIndex].values, to: project)
        let bestResult = try StaticAnalysis(options: analysisOptions)
            .solve(bestVariant.makeModel())
        return ParametricResult(
            axes: axes,
            samples: samples,
            objective: objective,
            bestIndex: bestIndex,
            bestModel: bestVariant.makeModel(),
            bestResult: bestResult
        )
    }

    private func applying(
        _ values: [Double],
        to project: MeshLabProject
    ) throws -> MeshLabProject {
        var variant = project
        for (axis, value) in zip(axes, values) {
            switch axis.parameter {
            case .youngModulus:
                variant.material = try ElasticMaterial(
                    youngModulus: value,
                    poissonRatio: variant.material.poissonRatio,
                    density: variant.material.density,
                    planeKinematics: variant.material.planeKinematics,
                    thickness: variant.material.thickness,
                    thermalConductivity: variant.material.thermalConductivity,
                    thermalExpansion: variant.material.thermalExpansion
                )
            case .poissonRatio:
                variant.material = try ElasticMaterial(
                    youngModulus: variant.material.youngModulus,
                    poissonRatio: value,
                    density: variant.material.density,
                    planeKinematics: variant.material.planeKinematics,
                    thickness: variant.material.thickness,
                    thermalConductivity: variant.material.thermalConductivity,
                    thermalExpansion: variant.material.thermalExpansion
                )
            case .thickness:
                variant.material = try ElasticMaterial(
                    youngModulus: variant.material.youngModulus,
                    poissonRatio: variant.material.poissonRatio,
                    density: variant.material.density,
                    planeKinematics: variant.material.planeKinematics,
                    thickness: value,
                    thermalConductivity: variant.material.thermalConductivity,
                    thermalExpansion: variant.material.thermalExpansion
                )
            case .loadScale:
                variant.loadScale = value
            }
        }
        return variant
    }

    private func objectiveValue(_ sample: ParametricSample) -> Double {
        switch objective {
        case .compliance: return sample.compliance
        case .maxDisplacement: return sample.maxDisplacement
        case .maxVonMises: return sample.maxVonMises
        }
    }

    private static func validate(
        _ value: Double,
        for parameter: DesignParameter
    ) throws {
        guard value.isFinite else {
            throw DesignError.invalidStudy("Parametric values must be finite")
        }
        switch parameter {
        case .youngModulus, .thickness:
            guard value > 0 else {
                throw DesignError.invalidStudy(
                    "Material stiffness and thickness must be positive"
                )
            }
        case .poissonRatio:
            guard value > -1, value < 0.5 else {
                throw DesignError.invalidStudy(
                    "Poisson ratio must lie between -1 and 0.5"
                )
            }
        case .loadScale:
            guard value >= 0 else {
                throw DesignError.invalidStudy("Load scale must be non-negative")
            }
        }
    }
}
