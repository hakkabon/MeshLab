import Foundation

/// Solver-facing contract for a square linear operator.
///
/// The contract deliberately contains no mesh or element semantics. It is the
/// seam through which MeshLab can consume a future NumericCore matrix-free
/// Krylov implementation without moving geometry or model ownership across the
/// package boundary.
public protocol FEMLinearOperator: Sendable {
    var dimension: Int { get }
    var diagonal: [Double] { get }
    func multiply(_ vector: [Double]) -> [Double]
}

public enum FEMOperatorError: Error, Equatable, Sendable {
    case invalidDimension
    case invalidContribution
    case degreeOfFreedomOutOfRange(Int)
}

/// Dense local contribution and its global degree-of-freedom map.
public struct FEMElementContribution: Sendable, Hashable {
    public let degreesOfFreedom: [Int]
    public let matrix: [Double]

    public init(degreesOfFreedom: [Int], matrix: [Double]) throws {
        guard !degreesOfFreedom.isEmpty,
              matrix.count == degreesOfFreedom.count * degreesOfFreedom.count,
              matrix.allSatisfy(\.isFinite) else {
            throw FEMOperatorError.invalidContribution
        }
        self.degreesOfFreedom = degreesOfFreedom
        self.matrix = matrix
    }
}

/// Element-by-element global stiffness operator for matrix-free solves.
public struct FEMElementOperator: FEMLinearOperator {
    public let dimension: Int
    public let contributions: [FEMElementContribution]
    public let diagonal: [Double]

    public init(
        dimension: Int,
        contributions: [FEMElementContribution]
    ) throws {
        guard dimension > 0, !contributions.isEmpty else {
            throw FEMOperatorError.invalidDimension
        }
        var diagonal = [Double](repeating: 0, count: dimension)
        for contribution in contributions {
            for (local, dof) in contribution.degreesOfFreedom.enumerated() {
                guard (0..<dimension).contains(dof) else {
                    throw FEMOperatorError.degreeOfFreedomOutOfRange(dof)
                }
                diagonal[dof] += contribution.matrix[
                    local * contribution.degreesOfFreedom.count + local
                ]
            }
        }
        self.dimension = dimension
        self.contributions = contributions
        self.diagonal = diagonal
    }

    public func multiply(_ vector: [Double]) -> [Double] {
        precondition(vector.count == dimension, "Operator and vector dimensions must match")
        var result = [Double](repeating: 0, count: dimension)
        for contribution in contributions {
            let size = contribution.degreesOfFreedom.count
            for row in 0..<size {
                var value = 0.0
                let offset = row * size
                for column in 0..<size {
                    value += contribution.matrix[offset + column]
                        * vector[contribution.degreesOfFreedom[column]]
                }
                result[contribution.degreesOfFreedom[row]] += value
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
        operator matrixFreeOperator: any FEMLinearOperator,
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
                dofCount: matrixFreeOperator.dimension
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
