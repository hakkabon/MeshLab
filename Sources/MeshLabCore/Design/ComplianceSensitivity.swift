import Foundation
import simd

/// Discrete adjoint sensitivity of linear-elastic compliance.
///
/// For fixed loads and homogeneous Dirichlet constraints, compliance is
/// `C = fᵀu = uᵀKu`. Its derivative with respect to an element stiffness
/// multiplier is `-uₑᵀKₑuₑ`; the compliance objective is self-adjoint, so the
/// primal solution is also the adjoint solution.
public struct ComplianceSensitivity: Sendable {
    public let compliance: Double
    /// Derivative with respect to each element's stiffness multiplier.
    public let elementStiffnessGradient: [Double]
    public let youngModulusGradient: Double
    /// `nil` for three-dimensional models, where thickness is not a stiffness
    /// parameter.
    public let thicknessGradient: Double?
    public let staticResult: StaticResult

    public func loadScaleGradient(currentScale: Double) -> Double {
        guard currentScale.isFinite, currentScale != 0 else { return 0 }
        return 2 * compliance / currentScale
    }
}

public enum ComplianceAdjoint {
    public static func solve(
        _ model: FEMModel,
        options: AnalysisOptions = AnalysisOptions()
    ) throws -> ComplianceSensitivity {
        guard !model.constraints.isEmpty else {
            throw DesignError.invalidStudy("A compliance solve needs a constraint")
        }
        guard model.constraints.allSatisfy({ $0.value == 0 }) else {
            throw DesignError.invalidStudy(
                "Compliance adjoint requires homogeneous Dirichlet constraints"
            )
        }
        guard model.temperatureChange.isEmpty else {
            throw DesignError.invalidStudy(
                "Compliance adjoint does not include thermal loading"
            )
        }

        let result = try StaticAnalysis(options: options).solve(model)
        let dimension = model.mesh.dimension
        var full = [Double](repeating: 0, count: model.mesh.dofCount)
        for (node, displacement) in result.displacements.enumerated() {
            let base = node * dimension
            full[base] = displacement.x
            if dimension > 1 { full[base + 1] = displacement.y }
            if dimension > 2 { full[base + 2] = displacement.z }
        }

        var elementGradient = [Double](
            repeating: 0,
            count: model.mesh.elements.count
        )
        for elementIndex in model.mesh.elements.indices {
            let data = try ElementKinematics.compute(
                mesh: model.mesh,
                material: model.material,
                elementIndex: elementIndex
            )
            let stiffness = data.stiffness()
            let dofs = model.elementDOFs(elementIndex)
            let local = dofs.map { full[$0] }
            var energy = 0.0
            for row in 0..<dofs.count {
                var product = 0.0
                for column in 0..<dofs.count {
                    product += stiffness[row * dofs.count + column] * local[column]
                }
                energy += local[row] * product
            }
            elementGradient[elementIndex] = -energy
        }

        let compliance = 2 * result.strainEnergy
        return ComplianceSensitivity(
            compliance: compliance,
            elementStiffnessGradient: elementGradient,
            youngModulusGradient: -compliance / model.material.youngModulus,
            thicknessGradient: dimension == 2
                ? -compliance / model.material.thickness
                : nil,
            staticResult: result
        )
    }
}
