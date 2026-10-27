import Accelerate
import Foundation
import NumericCoreSparse

public enum SparsePreconditionerKind: Sendable, Hashable, Codable {
    case none
    case jacobi
    case ilu0
    case incompleteCholesky
}

public struct SparseIterativeSettings: Sendable, Hashable, Codable {
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

/// Ordering used by reusable NumericCore factorizations.
public enum SparseOrderingKind: Sendable, Hashable, Codable {
    case natural
    case minimumDegree
}

/// Options for NumericCore's reusable direct factorizations.
public struct SparseDirectSettings: Sendable, Hashable, Codable {
    public var ordering: SparseOrderingKind
    public var pivotTolerance: Double
    public var dropTolerance: Double
    public var refinementSteps: Int
    public var refinementTolerance: Double

    public init(
        ordering: SparseOrderingKind = .minimumDegree,
        pivotTolerance: Double = 1e-12,
        dropTolerance: Double = 0,
        refinementSteps: Int = 3,
        refinementTolerance: Double = 1e-12
    ) {
        self.ordering = ordering
        self.pivotTolerance = pivotTolerance
        self.dropTolerance = dropTolerance
        self.refinementSteps = refinementSteps
        self.refinementTolerance = refinementTolerance
    }
}

/// Inertia reported by NumericCore's symmetric-indefinite LDLᵀ factorization.
public struct SparseInertiaReport: Sendable, Hashable {
    public let positive: Int
    public let negative: Int
    public let zero: Int

    public init(positive: Int, negative: Int, zero: Int) {
        self.positive = positive
        self.negative = negative
        self.zero = zero
    }
}

/// Linear solver strategies.
///
/// `automatic` uses Accelerate's hardware sparse LDLᵀ for symmetric systems
/// and NumericCore's reusable sparse LU for everything else. Explicit
/// NumericCore direct methods expose symbolic reuse and refinement, while its
/// iterative methods are available for very large systems where a direct
/// factorization is undesirable.
public enum SparseSolverMethod: Sendable, Hashable, Codable {
    case automatic
    case accelerateCholesky
    case accelerateLDLT
    case numericCoreCholesky
    /// Reusable pivoted sparse LU from NumericCore.
    case numericCoreLU
    /// Reusable symmetric-indefinite LDLᵀ from NumericCore.
    case numericCoreLDLT
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
    /// Backward error after iterative refinement, when reported by NumericCore.
    public let backwardError: Double?
    /// Number of iterative-refinement steps applied by NumericCore.
    public let refinementSteps: Int?
    /// Inertia for symmetric-indefinite LDLᵀ, when available.
    public let inertia: SparseInertiaReport?
}

/// A reusable linear solver for a fixed sparsity pattern.
///
/// Accelerate and NumericCore backends are both supported. The matrix is
/// assembled once and can be numerically refactored through ``refactor(with:)``
/// when material or boundary conditions change but the pattern does not.
public final class SparseSolver {
    public let size: Int
    public let method: SparseSolverMethod
    public let directSettings: SparseDirectSettings
    private let backend: any SparseSolverBackend

    public init(
        matrix: SparseMatrix,
        method: SparseSolverMethod = .automatic,
        directSettings: SparseDirectSettings = SparseDirectSettings()
    ) throws {
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
        self.directSettings = directSettings

        switch resolved {
        case .accelerateCholesky, .accelerateLDLT:
            backend = try AccelerateSparseBackend(matrix: matrix, method: resolved)
        case .numericCoreCholesky, .numericCoreLU, .numericCoreLDLT,
             .conjugateGradient, .biCGSTAB, .gmres:
            backend = try NumericCoreSparseBackend(
                matrix: matrix,
                method: resolved,
                settings: directSettings
            )
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

    /// Solves several right-hand sides through the same prepared backend.
    /// Direct methods reuse their symbolic and numerical factorization; iterative
    /// methods reuse the converted sparse matrix and configured preconditioner.
    public func solveMultipleWithReports(
        _ rightHandSides: [[Double]]
    ) throws -> [SparseSolveReport] {
        try rightHandSides.map { try solveWithReport($0) }
    }

    public func solveMultiple(_ rightHandSides: [[Double]]) throws -> [[Double]] {
        try solveMultipleWithReports(rightHandSides).map(\.solution)
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
        case .numericCoreLDLT:
            guard matrix.isSymmetric else {
                throw SparseSolverError.requiresSymmetricMatrix
            }
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
            converged: true,
            backwardError: nil,
            refinementSteps: nil,
            inertia: nil
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
    private let settings: SparseDirectSettings
    private var matrix: NumericCoreSparse.SparseMatrix<Double>
    private var luFactorization: NumericCoreSparse.SparseLUFactorization?
    private var ldltFactorization: NumericCoreSparse.SparseLDLTFactorization?

    init(
        matrix source: SparseMatrix,
        method: SparseSolverMethod,
        settings: SparseDirectSettings
    ) throws {
        self.method = method
        self.settings = settings
        let ncMatrix = try Self.makeMatrix(source)
        self.matrix = ncMatrix

        do {
            switch method {
            case .numericCoreLU:
                let ordering = Self.ordering(settings.ordering)
                let options = Self.numericOptions(settings)
                self.luFactorization = try NumericCoreSparse.SparseLUFactorization(
                    matrix: ncMatrix,
                    ordering: ordering,
                    options: options
                )
            case .numericCoreLDLT:
                let ordering = Self.ordering(settings.ordering)
                let options = Self.numericOptions(settings)
                self.ldltFactorization = try NumericCoreSparse.SparseLDLTFactorization(
                    matrix: ncMatrix,
                    ordering: ordering,
                    options: options
                )
            default:
                break
            }
        } catch {
            throw Self.map(error)
        }
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
                    converged: true,
                    backwardError: nil,
                    refinementSteps: 0,
                    inertia: nil
                )

            case .numericCoreLU:
                guard let factorization = luFactorization else {
                    throw SparseSolverError.numericCoreFailure("LU factorization is unavailable")
                }
                let result = try factorization.solveRefined(rhs)
                return SparseSolveReport(
                    solution: result.solution,
                    method: method,
                    iterations: nil,
                    relativeResidual: result.relativeResidual,
                    factorNonZeroCount: result.diagnostics.factorNonZeroCount,
                    converged: true,
                    backwardError: result.backwardError,
                    refinementSteps: result.refinementSteps,
                    inertia: nil
                )

            case .numericCoreLDLT:
                guard let factorization = ldltFactorization else {
                    throw SparseSolverError.numericCoreFailure("LDLT factorization is unavailable")
                }
                let result = try factorization.solveRefined(rhs)
                return SparseSolveReport(
                    solution: result.solution,
                    method: method,
                    iterations: nil,
                    relativeResidual: result.relativeResidual,
                    factorNonZeroCount: result.diagnostics.factorNonZeroCount,
                    converged: true,
                    backwardError: result.backwardError,
                    refinementSteps: result.refinementSteps,
                    inertia: Self.inertia(factorization.inertia)
                )

            case .conjugateGradient(let iterativeSettings):
                return try solveIteratively(
                    rhs: rhs,
                    method: .conjugateGradient,
                    settings: iterativeSettings
                )

            case .biCGSTAB(let iterativeSettings):
                return try solveIteratively(
                    rhs: rhs,
                    method: .biCGSTAB,
                    settings: iterativeSettings
                )

            case .gmres(let restart, let iterativeSettings):
                return try solveIteratively(
                    rhs: rhs,
                    method: .gmres(restart: restart),
                    settings: iterativeSettings
                )

            default:
                preconditionFailure("Unsupported NumericCore solver method")
            }
        } catch let error as SparseSolverError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func refactor(with source: SparseMatrix) throws {
        do {
            let newMatrix = try Self.makeMatrix(source)
            switch method {
            case .numericCoreLU:
                guard let factorization = luFactorization else {
                    throw SparseSolverError.numericCoreFailure("LU factorization is unavailable")
                }
                try factorization.refactor(with: newMatrix)
            case .numericCoreLDLT:
                guard let factorization = ldltFactorization else {
                    throw SparseSolverError.numericCoreFailure("LDLT factorization is unavailable")
                }
                try factorization.refactor(with: newMatrix)
            default:
                break
            }
            matrix = newMatrix
        } catch let error as SparseSolverError {
            throw error
        } catch {
            throw Self.map(error)
        }
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
            converged: result.converged,
            backwardError: nil,
            refinementSteps: nil,
            inertia: nil
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

    private static func ordering(
        _ ordering: SparseOrderingKind
    ) -> NumericCoreSparse.SparseOrdering {
        switch ordering {
        case .natural:
            return .natural
        case .minimumDegree:
            return .minimumDegree
        }
    }

    private static func numericOptions(
        _ settings: SparseDirectSettings
    ) -> NumericCoreSparse.SparseNumericOptions {
        NumericCoreSparse.SparseNumericOptions(
            pivotTolerance: settings.pivotTolerance,
            dropTolerance: settings.dropTolerance,
            refinementSteps: settings.refinementSteps,
            refinementTolerance: settings.refinementTolerance
        )
    }

    private static func inertia(
        _ inertia: NumericCoreSparse.SparseInertia
    ) -> SparseInertiaReport {
        SparseInertiaReport(
            positive: inertia.positive,
            negative: inertia.negative,
            zero: inertia.zero
        )
    }

    private static func map(_ error: Error) -> SparseSolverError {
        if let error = error as? SparseSolverError {
            return error
        }
        return .numericCoreFailure(String(describing: error))
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
            throw Self.map(error)
        }
    }
}
