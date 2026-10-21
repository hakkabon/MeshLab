import Foundation

/// Element-by-element global stiffness operator for matrix-free solves.
struct ElementStiffnessOperator: Sendable {
    struct Element: Sendable {
        let dofs: [Int]
        let size: Int
        let stiffness: [Double]
    }

    let dofCount: Int
    let elements: [Element]
    let diagonal: [Double]

    func multiply(_ vector: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: dofCount)
        for element in elements {
            for row in 0..<element.size {
                var value = 0.0
                let offset = row * element.size
                for column in 0..<element.size {
                    value += element.stiffness[offset + column]
                        * vector[element.dofs[column]]
                }
                result[element.dofs[row]] += value
            }
        }
        return result
    }
}

/// Jacobi-preconditioned conjugate gradient over an element-by-element
/// stiffness operator.
///
/// This is the matrix-free structural adapter used when a global sparse matrix
/// is undesirable. NumericCore owns general sparse/iterative solvers; this
/// adapter exists because NumericCore does not yet expose a public matrix-free
/// linear CG over a user-supplied operator. It should move upstream once that
/// API exists (ADR 0007).
struct MatrixFreeConjugateGradient {
    struct Result: Sendable {
        let solution: [Double]
        let iterations: Int
        let relativeResidual: Double
    }

    static func solve(
        operator matrixFreeOperator: ElementStiffnessOperator,
        freeDOFs: [Int],
        rightHandSide: [Double],
        options: MatrixFreeOptions
    ) throws -> Result {
        guard options.maximumIterations > 0,
              options.relativeTolerance.isFinite,
              options.relativeTolerance > 0 else {
            throw FEMError.invalidModel("Matrix-free solver options are invalid")
        }
        guard rightHandSide.count == freeDOFs.count else {
            throw FEMError.invalidModel(
                "Matrix-free right-hand side does not match the free DOF count"
            )
        }
        let rhsNorm = VectorMath.norm(rightHandSide)
        guard rhsNorm > 0 else {
            return Result(
                solution: [Double](repeating: 0, count: freeDOFs.count),
                iterations: 0,
                relativeResidual: 0
            )
        }

        var x = [Double](repeating: 0, count: freeDOFs.count)
        var residual = rightHandSide
        var preconditioned = applyPreconditioner(
            residual,
            freeDOFs: freeDOFs,
            diagonal: matrixFreeOperator.diagonal,
            enabled: options.useJacobiPreconditioner
        )
        var direction = preconditioned
        var residualDotPreconditioned = VectorMath.dot(residual, preconditioned)
        var relativeResidual = 1.0

        for iteration in 1...options.maximumIterations {
            try Task.checkCancellation()
            let fullDirection = expand(
                direction,
                freeDOFs: freeDOFs,
                dofCount: matrixFreeOperator.dofCount
            )
            let product = matrixFreeOperator.multiply(fullDirection)
            let denominator = VectorMath.dot(direction, freeDOFs.map { product[$0] })
            guard denominator.isFinite, denominator > 0 else {
                throw FEMError.solverFailure(
                    "Matrix-free CG encountered a non-positive search direction"
                )
            }
            let alpha = residualDotPreconditioned / denominator
            for index in x.indices {
                x[index] += alpha * direction[index]
                residual[index] -= alpha * product[freeDOFs[index]]
            }
            relativeResidual = VectorMath.norm(residual) / rhsNorm
            if relativeResidual <= options.relativeTolerance {
                return Result(
                    solution: x,
                    iterations: iteration,
                    relativeResidual: relativeResidual
                )
            }
            preconditioned = applyPreconditioner(
                residual,
                freeDOFs: freeDOFs,
                diagonal: matrixFreeOperator.diagonal,
                enabled: options.useJacobiPreconditioner
            )
            let nextDot = VectorMath.dot(residual, preconditioned)
            guard nextDot.isFinite else {
                throw FEMError.solverFailure(
                    "Matrix-free CG produced a non-finite residual"
                )
            }
            let beta = nextDot / residualDotPreconditioned
            for index in direction.indices {
                direction[index] = preconditioned[index] + beta * direction[index]
            }
            residualDotPreconditioned = nextDot
        }

        throw FEMError.solverFailure(
            "Matrix-free CG did not converge in \(options.maximumIterations) iterations "
                + "(relative residual \(relativeResidual))"
        )
    }

    private static func applyPreconditioner(
        _ residual: [Double],
        freeDOFs: [Int],
        diagonal: [Double],
        enabled: Bool
    ) -> [Double] {
        guard enabled else { return residual }
        return residual.indices.map { index in
            let value = diagonal[freeDOFs[index]]
            return value.isFinite && value > 0 ? residual[index] / value : residual[index]
        }
    }

    private static func expand(
        _ reduced: [Double],
        freeDOFs: [Int],
        dofCount: Int
    ) -> [Double] {
        var full = [Double](repeating: 0, count: dofCount)
        for (index, dof) in freeDOFs.enumerated() {
            full[dof] = reduced[index]
        }
        return full
    }
}
