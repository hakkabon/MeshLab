import Accelerate
import Foundation
import NumericCoreSparse

public enum SparsePreconditionerKind: Sendable, Hashable {
    case none
    case jacobi
    case ilu0
    case incompleteCholesky
}

public struct SparseIterativeSettings: Sendable, Hashable {
    public var maxIterations: Int
    public var tolerance: Double
    public var initialSolution: [Double]?
    public var preconditioner: SparsePreconditionerKind

    public init(
        maxIterations: Int = 1_000,
        tolerance: Double = 1e-8,
        initialSolution: [Double]? = nil,
        preconditioner: SparsePreconditionerKind = .jacobi
    ) {
        self.maxIterations = maxIterations
        self.tolerance = tolerance
        self.initialSolution = initialSolution
        self.preconditioner = preconditioner
    }
}

/// Linear solver strategies.
///
/// `automatic` uses Accelerate's hardware sparse Cholesky for symmetric
/// systems and NumericCore's Rust-backed sparse LU for everything else.
/// NumericCore's iterative methods and preconditioners are available for
/// very large systems where a direct factorization is undesirable.
public enum SparseSolverMethod: Sendable, Hashable {
    case automatic
    case accelerateCholesky
    case accelerateLDLT
    case numericCoreCholesky
    case numericCoreLU
    case conjugateGradient(SparseIterativeSettings)
    case biCGSTAB(SparseIterativeSettings)
    case gmres(restart: Int, settings: SparseIterativeSettings)
}

public enum SparseSolverError: Error, Equatable, Sendable {
    case emptyMatrix
    case dimensionMismatch
    case requiresSymmetricMatrix
    case missingPositiveDiagonal([Int])
    case factorizationFailed(status: Int32)
    case numericCoreFailure(String)
    case iterativeDidNotConverge(iterations: Int, relativeResidual: Double)
}

public struct SparseSolveReport: Sendable {
    public let solution: [Double]
    public let method: SparseSolverMethod
    public let iterations: Int?
    public let relativeResidual: Double?
    public let factorNonZeroCount: Int?
    public let converged: Bool
}

/// A reusable linear solver for a fixed sparsity pattern.
///
/// Accelerate and NumericCore backends are both supported. The matrix is
/// assembled once and can be numerically refactored through ``refactor(with:)``
/// when material or boundary conditions change but the pattern does not.
public final class SparseSolver {
    public let size: Int
    public let method: SparseSolverMethod
    private let backend: any SparseSolverBackend

    public init(matrix: SparseMatrix, method: SparseSolverMethod = .automatic) throws {
        guard matrix.rowCount > 0, matrix.columnCount > 0 else {
            throw SparseSolverError.emptyMatrix
        }
        guard matrix.rowCount == matrix.columnCount else {
            throw SparseSolverError.dimensionMismatch
        }
        guard matrix.nonzeroCount > 0 else {
            throw SparseSolverError.emptyMatrix
        }

        let resolved = try Self.resolve(method, matrix: matrix)
        self.size = matrix.rowCount
        self.method = resolved

        switch resolved {
        case .accelerateCholesky, .accelerateLDLT:
            backend = try AccelerateSparseBackend(matrix: matrix, method: resolved)
        case .numericCoreCholesky, .numericCoreLU,
             .conjugateGradient, .biCGSTAB, .gmres:
            backend = try NumericCoreSparseBackend(matrix: matrix, method: resolved)
        case .automatic:
            preconditionFailure("automatic is resolved before backend creation")
        }
    }

    public func solve(_ rhs: [Double]) throws -> [Double] {
        try solveWithReport(rhs).solution
    }

    public func solveWithReport(_ rhs: [Double]) throws -> SparseSolveReport {
        guard rhs.count == size else {
            throw SparseSolverError.dimensionMismatch
        }
        return try backend.solve(rhs)
    }

    public func refactor(with matrix: SparseMatrix) throws {
        guard matrix.rowCount == size, matrix.columnCount == size else {
            throw SparseSolverError.dimensionMismatch
        }
        try backend.refactor(with: matrix)
    }

    private static func resolve(
        _ method: SparseSolverMethod,
        matrix: SparseMatrix
    ) throws -> SparseSolverMethod {
        switch method {
        case .automatic:
            return matrix.isSymmetric ? .accelerateLDLT : .numericCoreLU
        case .accelerateCholesky, .accelerateLDLT:
            guard matrix.isSymmetric else {
                throw SparseSolverError.requiresSymmetricMatrix
            }
            let missing = matrix.missingDiagonalRows()
            guard missing.isEmpty else {
                throw SparseSolverError.missingPositiveDiagonal(missing)
            }
            return method
        case .numericCoreCholesky:
            // NumericCore validates symmetry and positive definiteness itself.
            return method
        case .numericCoreLU, .conjugateGradient, .biCGSTAB, .gmres:
            return method
        }
    }
}

private protocol SparseSolverBackend: AnyObject {
    func solve(_ rhs: [Double]) throws -> SparseSolveReport
    func refactor(with matrix: SparseMatrix) throws
}

// MARK: - Accelerate

private final class AccelerateSparseBackend: SparseSolverBackend {
    private let method: SparseSolverMethod
    private var matrix: SparseMatrix_Double
    private var factor: SparseOpaqueFactorization_Double
    private var patternRows: [Int]
    private var patternColumns: [Int32]

    init(matrix source: SparseMatrix, method: SparseSolverMethod) throws {
        self.method = method
        self.patternRows = source.rowStarts
        self.patternColumns = source.columnIndices
        self.matrix = try AccelerateSparseBackend.makeMatrix(source)
        self.factor = SparseFactor(Self.factorizationType(for: method), matrix)
        guard factor.status.rawValue >= 0 else {
            let status = factor.status.rawValue
            SparseCleanup(matrix)
            SparseCleanup(factor)
            throw SparseSolverError.factorizationFailed(status: status)
        }
    }

    deinit {
        SparseCleanup(matrix)
        SparseCleanup(factor)
    }

    func solve(_ rhs: [Double]) throws -> SparseSolveReport {
        var rightHandSide = rhs
        var solution = [Double](repeating: 0, count: rightHandSide.count)
        let count = Int32(rightHandSide.count)
        rightHandSide.withUnsafeMutableBufferPointer { rhsBuffer in
            solution.withUnsafeMutableBufferPointer { solutionBuffer in
                let rhsVector = DenseVector_Double(
                    count: count,
                    data: rhsBuffer.baseAddress!
                )
                let solutionVector = DenseVector_Double(
                    count: count,
                    data: solutionBuffer.baseAddress!
                )
                SparseSolve(factor, rhsVector, solutionVector)
            }
        }
        return SparseSolveReport(
            solution: solution,
            method: method,
            iterations: nil,
            relativeResidual: nil,
            factorNonZeroCount: nil,
            converged: true
        )
    }

    func refactor(with source: SparseMatrix) throws {
        let newMatrix = try Self.makeMatrix(source)
        let samePattern = source.rowStarts == patternRows
            && source.columnIndices == patternColumns

        if samePattern {
            var updatedFactor = factor
            SparseRefactor(newMatrix, &updatedFactor)
            guard updatedFactor.status.rawValue >= 0 else {
                let status = updatedFactor.status.rawValue
                SparseCleanup(newMatrix)
                throw SparseSolverError.factorizationFailed(status: status)
            }
            SparseCleanup(matrix)
            SparseCleanup(factor)
            matrix = newMatrix
            factor = updatedFactor
        } else {
            let newFactor = SparseFactor(Self.factorizationType(for: method), newMatrix)
            guard newFactor.status.rawValue >= 0 else {
                let status = newFactor.status.rawValue
                SparseCleanup(newMatrix)
                SparseCleanup(newFactor)
                throw SparseSolverError.factorizationFailed(status: status)
            }
            SparseCleanup(matrix)
            SparseCleanup(factor)
            matrix = newMatrix
            factor = newFactor
            patternRows = source.rowStarts
            patternColumns = source.columnIndices
        }
    }

    private static func factorizationType(for method: SparseSolverMethod) -> SparseFactorization_t {
        switch method {
        case .accelerateCholesky:
            return SparseFactorizationCholesky
        case .accelerateLDLT:
            return SparseFactorizationLDLT
        default:
            preconditionFailure("Unsupported Accelerate factorization")
        }
    }

    private static func makeMatrix(_ source: SparseMatrix) throws -> SparseMatrix_Double {
        let nnz = source.nonzeroCount
        guard nnz > 0 else {
            throw SparseSolverError.emptyMatrix
        }

        var rows = [Int32](repeating: 0, count: nnz)
        var columns = [Int32](repeating: 0, count: nnz)
        var values = [Double](repeating: 0, count: nnz)

        var index = 0
        for row in 0..<source.rowCount {
            for stored in source.rowStarts[row]..<source.rowStarts[row + 1] {
                rows[index] = Int32(row)
                columns[index] = source.columnIndices[stored]
                values[index] = source.values[stored]
                index += 1
            }
        }

        var attributes = SparseAttributes_t()
        if source.isSymmetric {
            attributes.kind = SparseSymmetric
            attributes.triangle = SparseLowerTriangle
        }

        return SparseConvertFromCoordinate(
            Int32(source.rowCount),
            Int32(source.columnCount),
            nnz,
            1,
            attributes,
            &rows,
            &columns,
            &values
        )
    }
}

// MARK: - NumericCore

private final class NumericCoreSparseBackend: SparseSolverBackend {
    private let method: SparseSolverMethod
    private var matrix: NumericCoreSparse.SparseMatrix<Double>

    init(matrix source: SparseMatrix, method: SparseSolverMethod) throws {
        self.method = method
        self.matrix = try NumericCoreSparseBackend.makeMatrix(source)
    }

    func solve(_ rhs: [Double]) throws -> SparseSolveReport {
        do {
            switch method {
            case .numericCoreCholesky:
                let result = try SparseLinearSolver.solveCholesky(matrix: matrix, rhs: rhs)
                return SparseSolveReport(
                    solution: result.solution,
                    method: method,
                    iterations: nil,
                    relativeResidual: result.relativeResidual,
                    factorNonZeroCount: result.factorNonZeroCount,
                    converged: true
                )

            case .numericCoreLU:
                let result = try SparseLinearSolver.solveLU(matrix: matrix, rhs: rhs)
                return SparseSolveReport(
                    solution: result.solution,
                    method: method,
                    iterations: nil,
                    relativeResidual: result.relativeResidual,
                    factorNonZeroCount: result.factorNonZeroCount,
                    converged: true
                )

            case .conjugateGradient(let settings):
                return try solveIteratively(
                    rhs: rhs,
                    method: .conjugateGradient,
                    settings: settings
                )

            case .biCGSTAB(let settings):
                return try solveIteratively(
                    rhs: rhs,
                    method: .biCGSTAB,
                    settings: settings
                )

            case .gmres(let restart, let settings):
                return try solveIteratively(
                    rhs: rhs,
                    method: .gmres(restart: restart),
                    settings: settings
                )

            default:
                preconditionFailure("Unsupported NumericCore solver method")
            }
        } catch let error as SparseSolverError {
            throw error
        } catch {
            throw SparseSolverError.numericCoreFailure(String(describing: error))
        }
    }

    func refactor(with source: SparseMatrix) throws {
        matrix = try Self.makeMatrix(source)
    }

    private func solveIteratively(
        rhs: [Double],
        method: NumericCoreSparse.SparseIterativeMethod,
        settings: SparseIterativeSettings
    ) throws -> SparseSolveReport {
        let options = NumericCoreSparse.SparseIterativeOptions(
            maxIterations: settings.maxIterations,
            tolerance: settings.tolerance,
            initialSolution: settings.initialSolution,
            preconditioner: Self.preconditioner(settings.preconditioner)
        )
        let result = try SparseLinearSolver.solve(
            matrix: matrix,
            rhs: rhs,
            method: method,
            options: options
        )
        guard result.converged else {
            throw SparseSolverError.iterativeDidNotConverge(
                iterations: result.iterations,
                relativeResidual: result.relativeResidual
            )
        }
        return SparseSolveReport(
            solution: result.solution,
            method: self.method,
            iterations: result.iterations,
            relativeResidual: result.relativeResidual,
            factorNonZeroCount: nil,
            converged: result.converged
        )
    }

    private static func preconditioner(
        _ preconditioner: SparsePreconditionerKind
    ) -> NumericCoreSparse.SparsePreconditioner {
        switch preconditioner {
        case .none:
            return .none
        case .jacobi:
            return .jacobi
        case .ilu0:
            return .ilu0
        case .incompleteCholesky:
            return .incompleteCholesky
        }
    }

    /// Expands the FEM-oriented lower-triangle CSR into canonical full CSR
    /// for NumericCore's solvers.
    private static func makeMatrix(
        _ source: SparseMatrix
    ) throws -> NumericCoreSparse.SparseMatrix<Double> {
        let size = source.rowCount
        guard source.columnCount == size else {
            throw SparseSolverError.dimensionMismatch
        }

        var counts = [Int](repeating: 0, count: size)
        for row in 0..<size {
            for index in source.rowStarts[row]..<source.rowStarts[row + 1] {
                counts[row] += 1
                let column = Int(source.columnIndices[index])
                if source.isSymmetric, column != row {
                    counts[column] += 1
                }
            }
        }

        var rowPointers = [Int](repeating: 0, count: size + 1)
        for row in 0..<size {
            rowPointers[row + 1] = rowPointers[row] + counts[row]
        }

        var columnIndices = [Int](repeating: 0, count: rowPointers[size])
        var values = [Double](repeating: 0, count: rowPointers[size])
        var cursor = rowPointers

        for row in 0..<size {
            for index in source.rowStarts[row]..<source.rowStarts[row + 1] {
                let column = Int(source.columnIndices[index])
                let value = source.values[index]

                columnIndices[cursor[row]] = column
                values[cursor[row]] = value
                cursor[row] += 1

                if source.isSymmetric, column != row {
                    columnIndices[cursor[column]] = row
                    values[cursor[column]] = value
                    cursor[column] += 1
                }
            }
        }

        // Accelerate's symmetric path stores a lower CSR. Mirroring produces
        // an unsorted full CSR, so restore canonical column ordering row by row.
        for row in 0..<size {
            let start = rowPointers[row]
            let end = rowPointers[row + 1]
            guard end > start + 1 else { continue }
            for index in (start + 1)..<end {
                let column = columnIndices[index]
                let value = values[index]
                var position = index - 1
                while position >= start, columnIndices[position] > column {
                    columnIndices[position + 1] = columnIndices[position]
                    values[position + 1] = values[position]
                    position -= 1
                }
                columnIndices[position + 1] = column
                values[position + 1] = value
            }
        }

        do {
            return try NumericCoreSparse.SparseMatrix(
                rows: size,
                cols: size,
                rowPointers: rowPointers,
                columnIndices: columnIndices,
                values: values
            )
        } catch {
            throw SparseSolverError.numericCoreFailure(String(describing: error))
        }
    }
}
