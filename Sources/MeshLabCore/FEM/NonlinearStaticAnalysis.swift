import Foundation
import NumericCoreOptimization
import simd

public struct NonlinearStaticOptions: Sendable, Hashable, Codable {
    public var loadSteps: Int
    public var maximumNewtonIterations: Int
    public var residualTolerance: Double
    public var stepTolerance: Double

    public init(
        loadSteps: Int = 10,
        maximumNewtonIterations: Int = 30,
        residualTolerance: Double = 1e-8,
        stepTolerance: Double = 1e-10
    ) {
        self.loadSteps = loadSteps
        self.maximumNewtonIterations = maximumNewtonIterations
        self.residualTolerance = residualTolerance
        self.stepTolerance = stepTolerance
    }
}

public struct NonlinearLoadStep: Sendable {
    public let loadFactor: Double
    public let iterations: Int
    public let residualNorm: Double
    public let termination: NonlinearSystemTermination
}

public struct NonlinearStaticResult: Sendable {
    public let staticResult: StaticResult
    public let loadSteps: [NonlinearLoadStep]
    public let totalNewtonIterations: Int
}

public enum NonlinearStaticError: Error, Equatable, Sendable {
    case invalidOptions
    case unsupportedElement(ElementType)
    case nonzeroPrescribedDisplacement
    case stepDidNotConverge(step: Int, termination: String)
    case invertedElement(Int)
}

/// Total-Lagrangian finite-strain tet4 analysis with a Saint Venant–Kirchhoff
/// material law. MeshLab owns the 3D element residual/tangent; NumericCore owns
/// the damped Newton and line-search algorithm.
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
              options.stepTolerance > 0 else {
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
        guard prescribed.values.allSatisfy({ $0 == 0 }) else {
            throw NonlinearStaticError.nonzeroPrescribedDisplacement
        }
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

        var point = [Double](repeating: 0, count: free.count)
        var steps: [NonlinearLoadStep] = []
        var totalIterations = 0
        for step in 1...options.loadSteps {
            try Task.checkCancellation()
            let loadFactor = Double(step) / Double(options.loadSteps)
            let solverOptions = NonlinearSystemOptions(
                maxIterations: options.maximumNewtonIterations,
                residualTolerance: options.residualTolerance,
                stepTolerance: options.stepTolerance,
                maxLineSearchIterations: 24,
                residualScale: [Double](repeating: 1 / externalNorm, count: free.count)
            )
            let solved = try NonlinearSystemSolver.solve(
                initial: point,
                options: solverOptions,
                observer: { _ in !Task.isCancelled }
            ) { candidate in
                let global = expand(candidate, free: free, count: model.mesh.dofCount)
                let response = try assemble(
                    displacement: global,
                    elements: elements,
                    dofCount: model.mesh.dofCount,
                    includeTangent: true
                )
                let residual = free.map { response.force[$0] - loadFactor * external[$0] }
                let jacobian = free.map { row in
                    free.map { column in
                        response.tangent[row * model.mesh.dofCount + column]
                    }
                }
                return NonlinearSystemEvaluation(residuals: residual, jacobian: jacobian)
            }
            if solved.termination == .cancelled {
                try Task.checkCancellation()
            }
            guard solved.termination == .convergedResidual
                    || solved.termination == .convergedStep else {
                throw NonlinearStaticError.stepDidNotConverge(
                    step: step,
                    termination: String(describing: solved.termination)
                )
            }
            point = solved.point
            totalIterations += solved.iterations
            steps.append(NonlinearLoadStep(
                loadFactor: loadFactor,
                iterations: solved.iterations,
                residualNorm: solved.residualNorm,
                termination: solved.termination
            ))
        }

        let global = expand(point, free: free, count: model.mesh.dofCount)
        let response = try assemble(
            displacement: global,
            elements: elements,
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
                strainEnergy: response.energy,
                iterations: totalIterations
            ),
            loadSteps: steps,
            totalNewtonIterations: totalIterations
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
    }

    private struct AssemblyResponse {
        let force: [Double]
        let tangent: [Double]
        let energy: Double
        let elements: [ElementResponse]
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
        dofCount: Int,
        includeTangent: Bool
    ) throws -> AssemblyResponse {
        var force = [Double](repeating: 0, count: dofCount)
        var tangent = includeTangent
            ? [Double](repeating: 0, count: dofCount * dofCount)
            : []
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
            let green = 0.5 * (
                simd_mul(deformation.transpose, deformation) - matrix_identity_double3x3
            )
            let trace = green[0][0] + green[1][1] + green[2][2]
            let secondPiola = element.lambda * trace * matrix_identity_double3x3
                + 2 * element.mu * green
            let firstPiola = simd_mul(deformation, secondPiola)
            energy += element.volume * (
                0.5 * element.lambda * trace * trace
                    + element.mu * doubleContraction(green, green)
            )

            for localNode in element.nodes.indices {
                let value = element.volume * (firstPiola * element.gradients[localNode])
                let base = element.nodes[localNode] * 3
                for axis in 0..<3 { force[base + axis] += value[axis] }
            }

            if includeTangent {
                for localColumn in element.nodes.indices {
                    let gradientColumn = element.gradients[localColumn]
                    for columnAxis in 0..<3 {
                        var deltaF = simd_double3x3(columns: (.zero, .zero, .zero))
                        for coordinate in 0..<3 {
                            deltaF[coordinate][columnAxis] = gradientColumn[coordinate]
                        }
                        let deltaGreen = 0.5 * (
                            simd_mul(deltaF.transpose, deformation)
                                + simd_mul(deformation.transpose, deltaF)
                        )
                        let deltaTrace = deltaGreen[0][0]
                            + deltaGreen[1][1]
                            + deltaGreen[2][2]
                        let deltaSecondPiola = element.lambda * deltaTrace
                            * matrix_identity_double3x3 + 2 * element.mu * deltaGreen
                        let deltaFirstPiola = simd_mul(deltaF, secondPiola)
                            + simd_mul(deformation, deltaSecondPiola)
                        let column = element.nodes[localColumn] * 3 + columnAxis
                        for localRow in element.nodes.indices {
                            let derivative = element.volume
                                * (deltaFirstPiola * element.gradients[localRow])
                            let rowBase = element.nodes[localRow] * 3
                            for rowAxis in 0..<3 {
                                tangent[(rowBase + rowAxis) * dofCount + column]
                                    += derivative[rowAxis]
                            }
                        }
                    }
                }
            }

            let cauchyUnscaled = simd_mul(
                simd_mul(deformation, secondPiola),
                deformation.transpose
            )
            let cauchy = simd_double3x3(columns: (
                cauchyUnscaled.columns.0 / jacobian,
                cauchyUnscaled.columns.1 / jacobian,
                cauchyUnscaled.columns.2 / jacobian
            ))
            let components = [
                cauchy[0][0], cauchy[1][1], cauchy[2][2],
                cauchy[0][1], cauchy[1][2], cauchy[2][0],
            ]
            responses.append(ElementResponse(
                index: element.index,
                nodes: element.nodes,
                stress: components,
                vonMises: ElementKinematics.vonMises(stress: components),
                volume: element.volume
            ))
        }
        return AssemblyResponse(
            force: force,
            tangent: tangent,
            energy: energy,
            elements: responses
        )
    }

    private func makeStaticResult(
        model: FEMModel,
        displacement: [Double],
        external: [Double],
        internalForce: [Double],
        free: [Int],
        prescribed: [Int: Double],
        elementResponses: [ElementResponse],
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

    private func expand(_ reduced: [Double], free: [Int], count: Int) -> [Double] {
        var value = [Double](repeating: 0, count: count)
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
