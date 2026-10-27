import Foundation

/// Deterministic block inverse/subspace iteration for the lowest modes of a
/// symmetric generalized eigenproblem. The reusable stiffness factorization and
/// multi-RHS solves provide the shift-invert operation at zero shift.
enum SparseGeneralizedEigenSolver {
    static func solve(
        stiffness: SparseMatrix,
        mass: SparseMatrix,
        modeCount: Int,
        maximumIterations: Int,
        relativeTolerance: Double
    ) throws -> (eigenvalues: [Double], eigenvectors: [[Double]]) {
        let dimension = stiffness.rowCount
        let width = min(dimension, modeCount + min(4, max(0, dimension - modeCount)))
        let linearSolver = try SparseSolver(
            matrix: stiffness,
            method: .numericCoreCholesky
        )
        var basis = (0..<width).map { column in
            (0..<dimension).map { row in
                sin(Double((row + 1) * (column + 1)) * .pi / Double(dimension + 1))
            }
        }
        basis = try massOrthonormalize(basis, mass: mass)

        var eigenvalues: [Double] = []
        for _ in 0..<maximumIterations {
            try Task.checkCancellation()
            let rightHandSides = basis.map { mass.multiply($0) }
            basis = try massOrthonormalize(
                linearSolver.solveMultiple(rightHandSides),
                mass: mass
            )
            let projectedK = projected(matrix: stiffness, basis: basis)
            let projectedM = projected(matrix: mass, basis: basis)
            let small = try SymmetricGeneralizedEigenSolver.solve(
                stiffness: projectedK,
                mass: projectedM,
                size: width
            )
            basis = rotate(basis: basis, vectors: small.eigenvectors)
            eigenvalues = small.eigenvalues

            var maximumResidual = 0.0
            for mode in 0..<min(modeCount, basis.count) {
                let kVector = stiffness.multiply(basis[mode])
                let mVector = mass.multiply(basis[mode])
                let residual = zip(kVector, mVector).map {
                    $0.0 - eigenvalues[mode] * $0.1
                }
                maximumResidual = max(
                    maximumResidual,
                    norm(residual) / max(1, norm(kVector))
                )
            }
            if maximumResidual <= relativeTolerance {
                return (
                    Array(eigenvalues.prefix(modeCount)),
                    Array(basis.prefix(modeCount))
                )
            }
        }
        throw FEMError.solverFailure(
            "Sparse modal subspace iteration did not converge in \(maximumIterations) iterations"
        )
    }

    private static func massOrthonormalize(
        _ vectors: [[Double]],
        mass: SparseMatrix
    ) throws -> [[Double]] {
        var result: [[Double]] = []
        for original in vectors {
            var vector = original
            for existing in result {
                let massVector = mass.multiply(vector)
                let projection = dot(existing, massVector)
                for index in vector.indices { vector[index] -= projection * existing[index] }
            }
            // Reorthogonalize once for clustered modes.
            for existing in result {
                let massVector = mass.multiply(vector)
                let projection = dot(existing, massVector)
                for index in vector.indices { vector[index] -= projection * existing[index] }
            }
            let squared = dot(vector, mass.multiply(vector))
            guard squared.isFinite, squared > 1e-24 else {
                throw FEMError.solverFailure("Sparse modal basis lost rank")
            }
            let scale = 1 / sqrt(squared)
            result.append(vector.map { $0 * scale })
        }
        return result
    }

    private static func projected(
        matrix: SparseMatrix,
        basis: [[Double]]
    ) -> [Double] {
        let products = basis.map { matrix.multiply($0) }
        var values = [Double](repeating: 0, count: basis.count * basis.count)
        for row in basis.indices {
            for column in basis.indices {
                values[row * basis.count + column] = dot(basis[row], products[column])
            }
        }
        return values
    }

    private static func rotate(
        basis: [[Double]],
        vectors: [[Double]]
    ) -> [[Double]] {
        vectors.map { coefficients in
            var value = [Double](repeating: 0, count: basis[0].count)
            for column in basis.indices {
                for row in value.indices {
                    value[row] += basis[column][row] * coefficients[column]
                }
            }
            return value
        }
    }

    private static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private static func norm(_ value: [Double]) -> Double {
        sqrt(dot(value, value))
    }
}
