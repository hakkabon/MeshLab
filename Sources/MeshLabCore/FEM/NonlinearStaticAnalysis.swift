import Foundation
import NumericCoreOptimization
import simd

public enum NonlinearConstitutiveModel: String, Sendable, Hashable, Codable, CaseIterable {
    case saintVenantKirchhoff = "saint-venant-kirchhoff"
    case neoHookean = "neo-hookean"
    case j2Plasticity = "j2-plasticity"
}

public struct NonlinearContactPlane: Sendable, Hashable, Codable {
    public var nodes: [Int]
    public var point: SIMD3<Double>
    public var normal: SIMD3<Double>
    public var penalty: Double

    public init(
        nodes: [Int],
        point: SIMD3<Double>,
        normal: SIMD3<Double>,
        penalty: Double
    ) {
        self.nodes = nodes
        self.point = point
        self.normal = normal
        self.penalty = penalty
    }
}

public struct NonlinearStaticOptions: Sendable, Hashable, Codable {
    public var loadSteps: Int
    public var maximumNewtonIterations: Int
    public var residualTolerance: Double
    public var stepTolerance: Double
    public var adaptiveStepping: Bool
    public var minimumLoadIncrement: Double
    public var maximumLoadIncrement: Double
    public var stepGrowthFactor: Double
    public var stepCutbackFactor: Double
    public var targetNewtonIterations: Int
    public var maximumStepRetries: Int
    public var constitutiveModel: NonlinearConstitutiveModel
    public var yieldStress: Double
    public var hardeningModulus: Double
    public var contacts: [NonlinearContactPlane]

    public init(
        loadSteps: Int = 10,
        maximumNewtonIterations: Int = 30,
        residualTolerance: Double = 1e-8,
        stepTolerance: Double = 1e-10,
        adaptiveStepping: Bool = true,
        minimumLoadIncrement: Double = 1e-4,
        maximumLoadIncrement: Double = 1,
        stepGrowthFactor: Double = 1.5,
        stepCutbackFactor: Double = 0.5,
        targetNewtonIterations: Int = 6,
        maximumStepRetries: Int = 8,
        constitutiveModel: NonlinearConstitutiveModel = .saintVenantKirchhoff,
        yieldStress: Double = 250e6,
        hardeningModulus: Double = 1e9,
        contacts: [NonlinearContactPlane] = []
    ) {
        self.loadSteps = loadSteps
        self.maximumNewtonIterations = maximumNewtonIterations
        self.residualTolerance = residualTolerance
        self.stepTolerance = stepTolerance
        self.adaptiveStepping = adaptiveStepping
        self.minimumLoadIncrement = minimumLoadIncrement
        self.maximumLoadIncrement = maximumLoadIncrement
        self.stepGrowthFactor = stepGrowthFactor
        self.stepCutbackFactor = stepCutbackFactor
        self.targetNewtonIterations = targetNewtonIterations
        self.maximumStepRetries = maximumStepRetries
        self.constitutiveModel = constitutiveModel
        self.yieldStress = yieldStress
        self.hardeningModulus = hardeningModulus
        self.contacts = contacts
    }

    private enum CodingKeys: String, CodingKey {
        case loadSteps, maximumNewtonIterations, residualTolerance, stepTolerance
        case adaptiveStepping, minimumLoadIncrement, maximumLoadIncrement
        case stepGrowthFactor, stepCutbackFactor, targetNewtonIterations
        case maximumStepRetries, constitutiveModel, yieldStress
        case hardeningModulus, contacts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            loadSteps: try container.decodeIfPresent(Int.self, forKey: .loadSteps) ?? 10,
            maximumNewtonIterations: try container.decodeIfPresent(
                Int.self, forKey: .maximumNewtonIterations
            ) ?? 30,
            residualTolerance: try container.decodeIfPresent(
                Double.self, forKey: .residualTolerance
            ) ?? 1e-8,
            stepTolerance: try container.decodeIfPresent(
                Double.self, forKey: .stepTolerance
            ) ?? 1e-10,
            adaptiveStepping: try container.decodeIfPresent(
                Bool.self, forKey: .adaptiveStepping
            ) ?? false,
            minimumLoadIncrement: try container.decodeIfPresent(
                Double.self, forKey: .minimumLoadIncrement
            ) ?? 1e-4,
            maximumLoadIncrement: try container.decodeIfPresent(
                Double.self, forKey: .maximumLoadIncrement
            ) ?? 1,
            stepGrowthFactor: try container.decodeIfPresent(
                Double.self, forKey: .stepGrowthFactor
            ) ?? 1.5,
            stepCutbackFactor: try container.decodeIfPresent(
                Double.self, forKey: .stepCutbackFactor
            ) ?? 0.5,
            targetNewtonIterations: try container.decodeIfPresent(
                Int.self, forKey: .targetNewtonIterations
            ) ?? 6,
            maximumStepRetries: try container.decodeIfPresent(
                Int.self, forKey: .maximumStepRetries
            ) ?? 8,
            constitutiveModel: try container.decodeIfPresent(
                NonlinearConstitutiveModel.self, forKey: .constitutiveModel
            ) ?? .saintVenantKirchhoff,
            yieldStress: try container.decodeIfPresent(
                Double.self, forKey: .yieldStress
            ) ?? 250e6,
            hardeningModulus: try container.decodeIfPresent(
                Double.self, forKey: .hardeningModulus
            ) ?? 1e9,
            contacts: try container.decodeIfPresent(
                [NonlinearContactPlane].self, forKey: .contacts
            ) ?? []
        )
    }
}

public struct NonlinearLoadStep: Sendable {
    public let loadFactor: Double
    public let loadIncrement: Double
    public let iterations: Int
    public let residualNorm: Double
    public let termination: NonlinearSystemTermination
}

public struct NonlinearStaticResult: Sendable {
    public let staticResult: StaticResult
    public let loadSteps: [NonlinearLoadStep]
    public let totalNewtonIterations: Int
    public let rejectedStepCount: Int
    public let elementStates: [FEMElementState]
}

public enum NonlinearStaticError: Error, Equatable, Sendable {
    case invalidOptions
    case unsupportedElement(ElementType)
    case nonzeroPrescribedDisplacement
    case stepDidNotConverge(step: Int, termination: String)
    case invertedElement(Int)
}

/// Sparse, adaptive total-Lagrangian finite-strain `tet4` analysis. MeshLab
/// owns constitutive integration, contact, residual/tangent assembly, and load
/// control; NumericCore supplies the sparse linear factorization at each Newton
/// iteration.
public struct NonlinearStaticAnalysis: Sendable {
    public var options: NonlinearStaticOptions

    public init(options: NonlinearStaticOptions = NonlinearStaticOptions()) {
        self.options = options
    }

    public func solve(_ model: FEMModel) throws -> NonlinearStaticResult {
        guard options.loadSteps > 0,
              options.maximumNewtonIterations > 0,
              options.residualTolerance.isFinite,
              options.residualTolerance > 0,
              options.stepTolerance.isFinite,
              options.stepTolerance > 0,
              options.minimumLoadIncrement.isFinite,
              options.minimumLoadIncrement > 0,
              options.maximumLoadIncrement.isFinite,
              options.maximumLoadIncrement >= options.minimumLoadIncrement,
              options.stepGrowthFactor.isFinite,
              options.stepGrowthFactor >= 1,
              options.stepCutbackFactor.isFinite,
              options.stepCutbackFactor > 0,
              options.stepCutbackFactor < 1,
              options.targetNewtonIterations > 0,
              options.maximumStepRetries >= 0,
              options.yieldStress.isFinite,
              options.yieldStress > 0,
              options.hardeningModulus.isFinite,
              options.hardeningModulus >= 0 else {
            throw NonlinearStaticError.invalidOptions
        }
        guard model.mesh.elements.allSatisfy({ $0.type == .tetrahedron4 }) else {
            throw NonlinearStaticError.unsupportedElement(
                model.mesh.elements.first { $0.type != .tetrahedron4 }!.type
            )
        }
        let prescribed = try FEMAssembly.prescribedMap(
            model.constraints,
            nodeCount: model.mesh.nodes.count,
            dimension: 3
        )
        try FEMAssembly.validateConstraintCoverage(
            mesh: model.mesh,
            prescribed: prescribed,
            dimension: 3
        )
        let free = try FEMAssembly.freeDOFs(
            count: model.mesh.dofCount,
            prescribed: prescribed
        )
        let external = try FEMAssembly.loadVector(model)
        let externalNorm = max(VectorMath.norm(free.map { external[$0] }), 1)
        let elements = try makeElements(model)
        let contacts = try validatedContacts(model.mesh)

        var point = [Double](repeating: 0, count: free.count)
        var states = [FEMElementState](repeating: FEMElementState(), count: elements.count)
        var steps: [NonlinearLoadStep] = []
        var totalIterations = 0
        var rejectedSteps = 0
        var retriesForCurrentStep = 0
        var loadFactor = 0.0
        var increment = min(
            options.maximumLoadIncrement,
            1 / Double(options.loadSteps)
        )
        while loadFactor < 1 - 1e-14 {
            try Task.checkCancellation()
            let target = min(1, loadFactor + increment)
            do {
                let solved = try solveStep(
                    initial: point,
                    committedStates: states,
                    loadFactor: target,
                    model: model,
                    elements: elements,
                    contacts: contacts,
                    free: free,
                    prescribed: prescribed,
                    external: external,
                    externalNorm: externalNorm
                )
                point = solved.point
                states = solved.states
                totalIterations += solved.iterations
                steps.append(NonlinearLoadStep(
                    loadFactor: target,
                    loadIncrement: target - loadFactor,
                    iterations: solved.iterations,
                    residualNorm: solved.residualNorm,
                    termination: solved.termination
                ))
                loadFactor = target
                retriesForCurrentStep = 0
                if options.adaptiveStepping {
                    if solved.iterations <= options.targetNewtonIterations {
                        increment = min(
                            options.maximumLoadIncrement,
                            increment * options.stepGrowthFactor
                        )
                    } else if solved.iterations > 2 * options.targetNewtonIterations {
                        increment = max(
                            options.minimumLoadIncrement,
                            increment * options.stepCutbackFactor
                        )
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard options.adaptiveStepping,
                      retriesForCurrentStep < options.maximumStepRetries else {
                    throw NonlinearStaticError.stepDidNotConverge(
                        step: steps.count + 1,
                        termination: String(describing: error)
                    )
                }
                rejectedSteps += 1
                retriesForCurrentStep += 1
                increment *= options.stepCutbackFactor
                guard increment >= options.minimumLoadIncrement else {
                    throw NonlinearStaticError.stepDidNotConverge(
                        step: steps.count + 1,
                        termination: "minimum load increment reached"
                    )
                }
            }
        }

        let global = expand(
            point, free: free, prescribed: prescribed,
            loadFactor: 1, count: model.mesh.dofCount
        )
        let response = try assemble(
            displacement: global,
            elements: elements,
            committedStates: states,
            contacts: contacts,
            dofCount: model.mesh.dofCount,
            includeTangent: false
        )
        return NonlinearStaticResult(
            staticResult: makeStaticResult(
                model: model,
                displacement: global,
                external: external,
                internalForce: response.force,
                free: free,
                prescribed: prescribed,
                elementResponses: response.elements,
                contactInternalForce: response.contactInternalForce,
                strainEnergy: response.energy,
                iterations: totalIterations
            ),
            loadSteps: steps,
            totalNewtonIterations: totalIterations,
            rejectedStepCount: rejectedSteps,
            elementStates: states
        )
    }

    private struct ReferenceElement: Sendable {
        let index: Int
        let nodes: [Int]
        let gradients: [SIMD3<Double>]
        let volume: Double
        let lambda: Double
        let mu: Double
    }

    private struct ElementResponse {
        let index: Int
        let nodes: [Int]
        let stress: [Double]
        let vonMises: Double
        let volume: Double
        let state: FEMElementState
    }

    private struct AssemblyResponse {
        let force: [Double]
        let contactInternalForce: [Double]
        let tangent: [SparseTriplet]
        let energy: Double
        let elements: [ElementResponse]
    }

    private struct StepSolution {
        let point: [Double]
        let states: [FEMElementState]
        let iterations: Int
        let residualNorm: Double
        let termination: NonlinearSystemTermination
    }

    private struct ContactPlane {
        let nodes: [Int]
        let referencePositions: [Int: SIMD3<Double>]
        let point: SIMD3<Double>
        let normal: SIMD3<Double>
        let penalty: Double
    }

    private func validatedContacts(_ mesh: Mesh) throws -> [ContactPlane] {
        try options.contacts.map { contact in
            let length = simd_length(contact.normal)
            guard !contact.nodes.isEmpty,
                  Set(contact.nodes).count == contact.nodes.count,
                  contact.nodes.allSatisfy(mesh.nodes.indices.contains),
                  contact.point.x.isFinite,
                  contact.point.y.isFinite,
                  contact.point.z.isFinite,
                  length.isFinite,
                  length > 1e-14,
                  contact.penalty.isFinite,
                  contact.penalty > 0 else {
                throw NonlinearStaticError.invalidOptions
            }
            return ContactPlane(
                nodes: contact.nodes,
                referencePositions: Dictionary(uniqueKeysWithValues: contact.nodes.map {
                    ($0, mesh.nodes[$0])
                }),
                point: contact.point,
                normal: contact.normal / length,
                penalty: contact.penalty
            )
        }
    }

    private func solveStep(
        initial: [Double],
        committedStates: [FEMElementState],
        loadFactor: Double,
        model: FEMModel,
        elements: [ReferenceElement],
        contacts: [ContactPlane],
        free: [Int],
        prescribed: [Int: Double],
        external: [Double],
        externalNorm: Double
    ) throws -> StepSolution {
        var point = initial
        var lastRelativeResidual = Double.infinity
        for iteration in 0..<options.maximumNewtonIterations {
            try Task.checkCancellation()
            let global = expand(
                point, free: free, prescribed: prescribed,
                loadFactor: loadFactor, count: model.mesh.dofCount
            )
            let response = try assemble(
                displacement: global,
                elements: elements,
                committedStates: committedStates,
                contacts: contacts,
                dofCount: model.mesh.dofCount,
                includeTangent: true
            )
            let residual = free.map {
                response.force[$0] - loadFactor * external[$0]
            }
            let residualNorm = VectorMath.norm(residual)
            let relativeResidual = residualNorm / externalNorm
            lastRelativeResidual = relativeResidual
            if relativeResidual <= options.residualTolerance {
                return StepSolution(
                    point: point,
                    states: response.elements.map(\.state),
                    iterations: iteration,
                    residualNorm: relativeResidual,
                    termination: .convergedResidual
                )
            }

            let tangent = try SparseMatrix.symmetric(
                size: model.mesh.dofCount,
                lowerTriplets: response.tangent
            )
            let reduced = try FEMAssembly.reduced(tangent, freeDOFs: free)
            let solver = try SparseSolver(
                matrix: reduced,
                // A finite-strain tangent can become indefinite near a limit
                // point; do not route it through an SPD-only backend.
                method: .numericCoreLU
            )
            let increment = try solver.solve(residual.map(-))
            let incrementNorm = VectorMath.norm(increment)
            let pointScale = max(VectorMath.norm(point), 1)
            guard increment.allSatisfy(\.isFinite) else { throw FEMError.nonFiniteSolution }

            var accepted: ([Double], AssemblyResponse, Double)?
            var alpha = 1.0
            for _ in 0..<24 {
                let candidate = zip(point, increment).map { $0 + alpha * $1 }
                do {
                    let candidateGlobal = expand(
                        candidate, free: free, prescribed: prescribed,
                        loadFactor: loadFactor, count: model.mesh.dofCount
                    )
                    let candidateResponse = try assemble(
                        displacement: candidateGlobal,
                        elements: elements,
                        committedStates: committedStates,
                        contacts: contacts,
                        dofCount: model.mesh.dofCount,
                        includeTangent: false
                    )
                    let candidateResidual = free.map {
                        candidateResponse.force[$0] - loadFactor * external[$0]
                    }
                    let norm = VectorMath.norm(candidateResidual)
                    if norm < residualNorm * (1 - 1e-4 * alpha) {
                        accepted = (candidate, candidateResponse, norm / externalNorm)
                        break
                    }
                } catch NonlinearStaticError.invertedElement {
                    // A smaller line-search step may restore a valid mapping.
                }
                alpha *= 0.5
            }
            guard let accepted else {
                throw FEMError.solverFailure("nonlinear line search failed")
            }
            point = accepted.0
            lastRelativeResidual = accepted.2
            if accepted.2 <= options.residualTolerance {
                return StepSolution(
                    point: point,
                    states: accepted.1.elements.map(\.state),
                    iterations: iteration + 1,
                    residualNorm: accepted.2,
                    termination: .convergedResidual
                )
            }
            if alpha * incrementNorm <= options.stepTolerance * pointScale {
                throw FEMError.solverFailure(
                    "Newton step stagnated at relative residual \(accepted.2)"
                )
            }
        }
        throw FEMError.solverFailure(
            "Newton iteration limit reached at relative residual \(lastRelativeResidual)"
        )
    }

    private func makeElements(_ model: FEMModel) throws -> [ReferenceElement] {
        try model.mesh.elements.indices.map { index in
            let material = try model.material(forElement: index)
            let data = try ElementKinematics.compute(
                mesh: model.mesh,
                material: material,
                elementIndex: index
            )
            return ReferenceElement(
                index: index,
                nodes: data.nodeIndices,
                gradients: data.shapeGradients,
                volume: data.measure,
                lambda: material.lameLambda,
                mu: material.shearModulus
            )
        }
    }

    private func assemble(
        displacement: [Double],
        elements: [ReferenceElement],
        committedStates: [FEMElementState],
        contacts: [ContactPlane],
        dofCount: Int,
        includeTangent: Bool
    ) throws -> AssemblyResponse {
        var force = [Double](repeating: 0, count: dofCount)
        var contactInternalForce = [Double](repeating: 0, count: dofCount)
        var tangent: [SparseTriplet] = []
        if includeTangent { tangent.reserveCapacity(elements.count * 78) }
        var energy = 0.0
        var responses: [ElementResponse] = []
        responses.reserveCapacity(elements.count)

        for element in elements {
            try Task.checkCancellation()
            var deformation = matrix_identity_double3x3
            for localNode in element.nodes.indices {
                let node = element.nodes[localNode]
                let value = SIMD3<Double>(
                    displacement[node * 3],
                    displacement[node * 3 + 1],
                    displacement[node * 3 + 2]
                )
                deformation += outer(value, element.gradients[localNode])
            }
            let jacobian = deformation.determinant
            guard jacobian.isFinite, jacobian > 1e-8 else {
                throw NonlinearStaticError.invertedElement(element.index)
            }
            let materialResponse = try constitutiveResponse(
                deformation: deformation,
                element: element,
                committedState: committedStates[element.index]
            )
            energy += element.volume * materialResponse.energy

            for localNode in element.nodes.indices {
                let value = element.volume
                    * (materialResponse.firstPiola * element.gradients[localNode])
                let base = element.nodes[localNode] * 3
                for axis in 0..<3 {
                    force[base + axis] += value[axis]
                }
            }

            if includeTangent {
                for localColumn in element.nodes.indices {
                    let gradientColumn = element.gradients[localColumn]
                    for columnAxis in 0..<3 {
                        var axis = SIMD3<Double>.zero
                        axis[columnAxis] = 1
                        let deltaF = outer(axis, gradientColumn)
                        let deltaFirstPiola = try constitutiveTangentAction(
                            deformation: deformation,
                            direction: deltaF,
                            element: element,
                            committedState: committedStates[element.index]
                        )
                        let column = element.nodes[localColumn] * 3 + columnAxis
                        for localRow in element.nodes.indices {
                            let derivative = element.volume
                                * (deltaFirstPiola * element.gradients[localRow])
                            let rowBase = element.nodes[localRow] * 3
                            for rowAxis in 0..<3 {
                                let row = rowBase + rowAxis
                                if row >= column, derivative[rowAxis] != 0 {
                                    tangent.append(SparseTriplet(
                                        row: row,
                                        column: column,
                                        value: derivative[rowAxis]
                                    ))
                                }
                            }
                        }
                    }
                }
            }

            let cauchy = materialResponse.cauchy
            let components = [
                cauchy[0][0], cauchy[1][1], cauchy[2][2],
                cauchy[0][1], cauchy[1][2], cauchy[2][0],
            ]
            responses.append(ElementResponse(
                index: element.index,
                nodes: element.nodes,
                stress: components,
                vonMises: ElementKinematics.vonMises(stress: components),
                volume: element.volume,
                state: materialResponse.state
            ))
        }
        for contact in contacts {
            for node in contact.nodes {
                let base = node * 3
                let position = contact.referencePositions[node]! + SIMD3<Double>(
                    displacement[base], displacement[base + 1], displacement[base + 2]
                )
                let gap = simd_dot(position - contact.point, contact.normal)
                guard gap < 0 else { continue }
                let value = contact.penalty * gap * contact.normal
                for axis in 0..<3 {
                    force[base + axis] += value[axis]
                    contactInternalForce[base + axis] += value[axis]
                }
                energy += 0.5 * contact.penalty * gap * gap
                if includeTangent {
                    for rowAxis in 0..<3 {
                        for columnAxis in 0...rowAxis {
                            let entry = contact.penalty
                                * contact.normal[rowAxis] * contact.normal[columnAxis]
                            if entry != 0 {
                                tangent.append(SparseTriplet(
                                    row: base + rowAxis,
                                    column: base + columnAxis,
                                    value: entry
                                ))
                            }
                        }
                    }
                }
            }
        }
        return AssemblyResponse(
            force: force,
            contactInternalForce: contactInternalForce,
            tangent: tangent,
            energy: energy,
            elements: responses
        )
    }

    private struct MaterialPointResponse {
        let firstPiola: simd_double3x3
        let cauchy: simd_double3x3
        let energy: Double
        let state: FEMElementState
    }

    private func constitutiveResponse(
        deformation: simd_double3x3,
        element: ReferenceElement,
        committedState: FEMElementState
    ) throws -> MaterialPointResponse {
        let jacobian = deformation.determinant
        guard jacobian.isFinite, jacobian > 1e-8 else {
            throw NonlinearStaticError.invertedElement(element.index)
        }
        let firstPiola: simd_double3x3
        let energy: Double
        let state: FEMElementState
        switch options.constitutiveModel {
        case .saintVenantKirchhoff:
            let green = greenStrain(deformation)
            let trace = matrixTrace(green)
            let secondPiola = element.lambda * trace * matrix_identity_double3x3
                + 2 * element.mu * green
            firstPiola = simd_mul(deformation, secondPiola)
            energy = 0.5 * element.lambda * trace * trace
                + element.mu * doubleContraction(green, green)
            state = committedState

        case .neoHookean:
            let logJ = log(jacobian)
            let inverseTranspose = deformation.inverse.transpose
            let coefficient = element.lambda * logJ - element.mu
            firstPiola = element.mu * deformation + coefficient * inverseTranspose
            let rightCauchyGreen = simd_mul(deformation.transpose, deformation)
            energy = 0.5 * element.mu * (matrixTrace(rightCauchyGreen) - 3)
                - element.mu * logJ + 0.5 * element.lambda * logJ * logJ
            state = committedState

        case .j2Plasticity:
            guard committedState.values.isEmpty || committedState.values.count == 7 else {
                throw FEMError.invalidModel("J2 element state must contain seven values")
            }
            let values = committedState.values.isEmpty
                ? [Double](repeating: 0, count: 7)
                : committedState.values
            var plastic = symmetricTensor(Array(values.prefix(6)))
            var equivalentPlasticStrain = values[6]
            let green = greenStrain(deformation)
            let elasticTrial = green - plastic
            let trialTrace = matrixTrace(elasticTrial)
            let trialStress = element.lambda * trialTrace * matrix_identity_double3x3
                + 2 * element.mu * elasticTrial
            let pressure = matrixTrace(trialStress) / 3
            let deviator = trialStress - pressure * matrix_identity_double3x3
            let equivalent = sqrt(max(0, 1.5 * doubleContraction(deviator, deviator)))
            let yield = options.yieldStress
                + options.hardeningModulus * equivalentPlasticStrain
            let overstress = equivalent - yield
            let secondPiola: simd_double3x3
            if overstress > 0, equivalent > 1e-20 {
                let plasticIncrement = overstress
                    / (3 * element.mu + options.hardeningModulus)
                let flow = (1.5 / equivalent) * deviator
                plastic += plasticIncrement * flow
                equivalentPlasticStrain += plasticIncrement
                secondPiola = pressure * matrix_identity_double3x3
                    + (1 - 3 * element.mu * plasticIncrement / equivalent) * deviator
            } else {
                secondPiola = trialStress
            }
            let elastic = green - plastic
            let elasticTrace = matrixTrace(elastic)
            energy = 0.5 * element.lambda * elasticTrace * elasticTrace
                + element.mu * doubleContraction(elastic, elastic)
                + 0.5 * options.hardeningModulus
                    * equivalentPlasticStrain * equivalentPlasticStrain
            firstPiola = simd_mul(deformation, secondPiola)
            state = FEMElementState(values: tensorValues(plastic) + [equivalentPlasticStrain])
        }
        let cauchyUnscaled = simd_mul(firstPiola, deformation.transpose)
        let cauchy = simd_double3x3(columns: (
            cauchyUnscaled.columns.0 / jacobian,
            cauchyUnscaled.columns.1 / jacobian,
            cauchyUnscaled.columns.2 / jacobian
        ))
        return MaterialPointResponse(
            firstPiola: firstPiola,
            cauchy: cauchy,
            energy: energy,
            state: state
        )
    }

    private func constitutiveTangentAction(
        deformation: simd_double3x3,
        direction: simd_double3x3,
        element: ReferenceElement,
        committedState: FEMElementState
    ) throws -> simd_double3x3 {
        switch options.constitutiveModel {
        case .saintVenantKirchhoff:
            let green = greenStrain(deformation)
            let trace = matrixTrace(green)
            let secondPiola = element.lambda * trace * matrix_identity_double3x3
                + 2 * element.mu * green
            let deltaGreen = 0.5 * (
                simd_mul(direction.transpose, deformation)
                    + simd_mul(deformation.transpose, direction)
            )
            let deltaSecondPiola = element.lambda * matrixTrace(deltaGreen)
                * matrix_identity_double3x3 + 2 * element.mu * deltaGreen
            return simd_mul(direction, secondPiola)
                + simd_mul(deformation, deltaSecondPiola)

        case .neoHookean:
            let inverseTranspose = deformation.inverse.transpose
            let logJ = log(deformation.determinant)
            let trace = matrixTrace(simd_mul(deformation.inverse, direction))
            let deltaInverseTranspose = -simd_mul(
                simd_mul(inverseTranspose, direction.transpose),
                inverseTranspose
            )
            return element.mu * direction
                + element.lambda * trace * inverseTranspose
                + (element.lambda * logJ - element.mu) * deltaInverseTranspose

        case .j2Plasticity:
            let directionNorm = sqrt(doubleContraction(direction, direction))
            let deformationNorm = sqrt(doubleContraction(deformation, deformation))
            let step = 1e-7 * max(1, deformationNorm) / max(directionNorm, 1e-30)
            let plus = try constitutiveResponse(
                deformation: deformation + step * direction,
                element: element,
                committedState: committedState
            ).firstPiola
            let minus = try constitutiveResponse(
                deformation: deformation - step * direction,
                element: element,
                committedState: committedState
            ).firstPiola
            return (0.5 / step) * (plus - minus)
        }
    }

    private func greenStrain(_ deformation: simd_double3x3) -> simd_double3x3 {
        0.5 * (simd_mul(deformation.transpose, deformation) - matrix_identity_double3x3)
    }

    private func matrixTrace(_ value: simd_double3x3) -> Double {
        value[0][0] + value[1][1] + value[2][2]
    }

    private func symmetricTensor(_ values: [Double]) -> simd_double3x3 {
        simd_double3x3(columns: (
            SIMD3(values[0], values[3], values[5]),
            SIMD3(values[3], values[1], values[4]),
            SIMD3(values[5], values[4], values[2])
        ))
    }

    private func tensorValues(_ value: simd_double3x3) -> [Double] {
        [
            value[0][0], value[1][1], value[2][2],
            value[1][0], value[2][1], value[0][2],
        ]
    }

    private func makeStaticResult(
        model: FEMModel,
        displacement: [Double],
        external: [Double],
        internalForce: [Double],
        free: [Int],
        prescribed: [Int: Double],
        elementResponses: [ElementResponse],
        contactInternalForce: [Double],
        strainEnergy: Double,
        iterations: Int
    ) -> StaticResult {
        let vectors = model.mesh.nodes.indices.map { node in
            SIMD3<Double>(
                displacement[node * 3],
                displacement[node * 3 + 1],
                displacement[node * 3 + 2]
            )
        }
        let residual = zip(internalForce, external).map(-)
        var reactions = [SIMD3<Double>](repeating: .zero, count: model.mesh.nodes.count)
        for node in model.mesh.nodes.indices {
            for axis in 0..<3 where prescribed[node * 3 + axis] != nil {
                reactions[node][axis] = residual[node * 3 + axis]
            }
            reactions[node] -= SIMD3<Double>(
                contactInternalForce[node * 3],
                contactInternalForce[node * 3 + 1],
                contactInternalForce[node * 3 + 2]
            )
        }
        var nodalStress = [Double](repeating: 0, count: model.mesh.nodes.count)
        var counts = [Int](repeating: 0, count: model.mesh.nodes.count)
        let stresses = elementResponses.map { value in
            for node in value.nodes {
                nodalStress[node] += value.vonMises
                counts[node] += 1
            }
            return ElementStress(
                elementIndex: value.index,
                components: value.stress,
                vonMises: value.vonMises,
                measure: value.volume
            )
        }
        for node in nodalStress.indices where counts[node] > 0 {
            nodalStress[node] /= Double(counts[node])
        }
        let freeResidual = free.map { abs(residual[$0]) }.max() ?? 0
        let scale = max(VectorMath.norm(external), VectorMath.norm(internalForce), 1e-30)
        var appliedForce = SIMD3<Double>.zero
        var reactionForce = SIMD3<Double>.zero
        var appliedMoment = SIMD3<Double>.zero
        var reactionMoment = SIMD3<Double>.zero
        for node in model.mesh.nodes.indices {
            let applied = SIMD3<Double>(
                external[node * 3], external[node * 3 + 1], external[node * 3 + 2]
            )
            appliedForce += applied
            reactionForce += reactions[node]
            let deformedPosition = model.mesh.nodes[node] + vectors[node]
            appliedMoment += simd_cross(deformedPosition, applied)
            reactionMoment += simd_cross(deformedPosition, reactions[node])
        }
        return StaticResult(
            displacements: vectors,
            elementStresses: stresses,
            nodalVonMises: nodalStress,
            reactions: reactions,
            strainEnergy: strainEnergy,
            solveReport: SparseSolveReport(
                solution: free.map { displacement[$0] },
                method: .numericCoreLU,
                iterations: iterations,
                relativeResidual: freeResidual / scale,
                factorNonZeroCount: nil,
                converged: true,
                backwardError: nil,
                refinementSteps: nil,
                inertia: nil
            ),
            maxDisplacement: vectors.map(simd_length).max() ?? 0,
            maxVonMises: stresses.map(\.vonMises).max() ?? 0,
            equilibrium: StaticEquilibriumReport(
                appliedForce: appliedForce,
                reactionForce: reactionForce,
                forceImbalance: appliedForce + reactionForce,
                appliedMoment: appliedMoment,
                reactionMoment: reactionMoment,
                momentImbalance: appliedMoment + reactionMoment,
                maximumFreeResidual: freeResidual,
                relativeFreeResidual: freeResidual / scale
            )
        )
    }

    private func expand(
        _ reduced: [Double],
        free: [Int],
        prescribed: [Int: Double],
        loadFactor: Double,
        count: Int
    ) -> [Double] {
        var value = [Double](repeating: 0, count: count)
        for (dof, prescribedValue) in prescribed {
            value[dof] = loadFactor * prescribedValue
        }
        for (index, dof) in free.enumerated() { value[dof] = reduced[index] }
        return value
    }

    private func outer(
        _ first: SIMD3<Double>,
        _ second: SIMD3<Double>
    ) -> simd_double3x3 {
        simd_double3x3(columns: (
            first * second.x,
            first * second.y,
            first * second.z
        ))
    }

    private func doubleContraction(
        _ first: simd_double3x3,
        _ second: simd_double3x3
    ) -> Double {
        var value = 0.0
        for row in 0..<3 {
            for column in 0..<3 { value += first[column][row] * second[column][row] }
        }
        return value
    }
}
