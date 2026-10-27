import Foundation

/// Opaque integration-point history owned by an element formulation.
/// Linear elements use an empty state; nonlinear constitutive kernels can
/// persist plastic strain, hardening, damage, or other history variables.
public struct FEMElementState: Sendable, Hashable, Codable {
    public var values: [Double]

    public init(values: [Double] = []) {
        self.values = values
    }
}

public struct FEMElementEvaluationRequest: Sendable {
    public let mesh: Mesh
    public let elementIndex: Int
    public let material: ElasticMaterial
    public let localDisplacement: [Double]
    public let initialStrain: [Double]
    public let stiffnessScale: Double
    public let state: FEMElementState

    public init(
        mesh: Mesh,
        elementIndex: Int,
        material: ElasticMaterial,
        localDisplacement: [Double],
        initialStrain: [Double] = [],
        stiffnessScale: Double = 1,
        state: FEMElementState = FEMElementState()
    ) {
        self.mesh = mesh
        self.elementIndex = elementIndex
        self.material = material
        self.localDisplacement = localDisplacement
        self.initialStrain = initialStrain
        self.stiffnessScale = stiffnessScale
        self.state = state
    }
}

/// Solver-facing response of one element in row-major local storage.
public struct FEMElementEvaluation: Sendable, Hashable {
    public let elementIndex: Int
    public let elementType: ElementType
    public let degreesOfFreedom: [Int]
    public let internalForce: [Double]
    public let tangent: [Double]
    public let consistentMass: [Double]
    public let stress: [Double]
    public let strainEnergy: Double
    public let measure: Double
    public let state: FEMElementState
}

/// Common residual/tangent/mass/state contract for current and future 3D
/// element formulations. Global assembly and solver selection remain outside
/// the kernel.
public protocol FEMElementKernel: Sendable {
    func evaluate(_ request: FEMElementEvaluationRequest) throws -> FEMElementEvaluation
}

/// Adapter for MeshLab's constant-gradient tri3 and tet4 formulations.
public struct LinearContinuumElementKernel: FEMElementKernel {
    public init() {}

    public func evaluate(
        _ request: FEMElementEvaluationRequest
    ) throws -> FEMElementEvaluation {
        guard request.mesh.elements.indices.contains(request.elementIndex),
              request.stiffnessScale.isFinite,
              request.stiffnessScale >= 0,
              request.state.values.allSatisfy(\.isFinite) else {
            throw FEMError.invalidModel("Element evaluation request is invalid")
        }
        let data = try ElementKinematics.compute(
            mesh: request.mesh,
            material: request.material,
            elementIndex: request.elementIndex
        )
        guard request.localDisplacement.count == data.dofCount,
              request.localDisplacement.allSatisfy(\.isFinite),
              (request.initialStrain.isEmpty
                  || request.initialStrain.count == data.strainCount),
              request.initialStrain.allSatisfy(\.isFinite) else {
            throw FEMError.invalidModel("Element field dimensions are invalid")
        }

        let tangent = data.stiffness().map { $0 * request.stiffnessScale }
        let stress = data.stress(
            localDisplacement: request.localDisplacement,
            initialStrain: request.initialStrain
        ).map { $0 * request.stiffnessScale }
        let internalForce = data.internalForce(
            localDisplacement: request.localDisplacement,
            initialStrain: request.initialStrain
        ).map { $0 * request.stiffnessScale }
        let element = request.mesh.elements[request.elementIndex]
        let dimension = request.mesh.dimension
        let dofs = element.nodes.flatMap { node in
            (0..<dimension).map { node * dimension + $0 }
        }
        return FEMElementEvaluation(
            elementIndex: request.elementIndex,
            elementType: element.type,
            degreesOfFreedom: dofs,
            internalForce: internalForce,
            tangent: tangent,
            consistentMass: data.mass(density: request.material.density),
            stress: stress,
            strainEnergy: data.strainEnergy(
                localDisplacement: request.localDisplacement,
                initialStrain: request.initialStrain
            ) * request.stiffnessScale,
            measure: data.measure,
            state: request.state
        )
    }
}
