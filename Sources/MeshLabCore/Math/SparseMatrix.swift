import Foundation

public struct SparseTriplet: Sendable, Equatable {
    public var row: Int
    public var column: Int
    public var value: Double

    public init(row: Int, column: Int, value: Double) {
        self.row = row
        self.column = column
        self.value = value
    }
}

public enum SparseMatrixError: Error, Equatable, Sendable {
    case invalidDimensions
    case indexOutOfRange
    case nonFiniteValue
    case notSquare
    case empty
    case tooLarge
}

/// Compressed Sparse Row (CSR) matrix.
///
/// Symmetric matrices store only the lower triangle (`row >= column`). This is
/// the representation required by Accelerate's Cholesky and LDLᵀ
/// factorizations, and it halves both the assembly and factorization cost for
/// FEM stiffness matrices.
public struct SparseMatrix: Sendable {
    public let rowCount: Int
    public let columnCount: Int
    public let isSymmetric: Bool
    public private(set) var rowStarts: [Int]
    public private(set) var columnIndices: [Int32]
    public private(set) var values: [Double]

    public init(
        rows: Int,
        columns: Int,
        triplets: [SparseTriplet],
        symmetric: Bool = false
    ) throws {
        guard rows > 0, columns > 0 else {
            throw SparseMatrixError.invalidDimensions
        }
        if symmetric, rows != columns {
            throw SparseMatrixError.notSquare
        }
        guard rows <= Int(Int32.max), columns <= Int(Int32.max) else {
            throw SparseMatrixError.tooLarge
        }

        self.rowCount = rows
        self.columnCount = columns
        self.isSymmetric = symmetric

        var entries: [SparseTriplet] = []
        entries.reserveCapacity(triplets.count)

        for triplet in triplets {
            guard triplet.value.isFinite else {
                throw SparseMatrixError.nonFiniteValue
            }
            guard (0..<rows).contains(triplet.row), (0..<columns).contains(triplet.column) else {
                throw SparseMatrixError.indexOutOfRange
            }

            if symmetric {
                entries.append(SparseTriplet(
                    row: Swift.max(triplet.row, triplet.column),
                    column: Swift.min(triplet.row, triplet.column),
                    value: triplet.value
                ))
            } else {
                entries.append(triplet)
            }
        }

        entries.sort {
            $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row
        }

        var rowStarts = [Int](repeating: 0, count: rows + 1)
        var columnIndices: [Int32] = []
        var values: [Double] = []
        columnIndices.reserveCapacity(entries.count)
        values.reserveCapacity(entries.count)

        var cursor = 0
        for row in 0..<rows {
            rowStarts[row] = columnIndices.count
            while cursor < entries.count, entries[cursor].row == row {
                let column = entries[cursor].column
                var value = entries[cursor].value
                cursor += 1
                while cursor < entries.count,
                      entries[cursor].row == row,
                      entries[cursor].column == column {
                    value += entries[cursor].value
                    cursor += 1
                }
                columnIndices.append(Int32(column))
                values.append(value)
            }
        }
        rowStarts[rows] = columnIndices.count

        self.rowStarts = rowStarts
        self.columnIndices = columnIndices
        self.values = values
    }

    public static func symmetric(
        size: Int,
        lowerTriplets: [SparseTriplet]
    ) throws -> SparseMatrix {
        try SparseMatrix(
            rows: size,
            columns: size,
            triplets: lowerTriplets,
            symmetric: true
        )
    }

    public var nonzeroCount: Int {
        values.count
    }

    public func multiply(_ vector: [Double]) -> [Double] {
        precondition(vector.count == columnCount, "Vector dimension does not match matrix")
        var result = [Double](repeating: 0, count: rowCount)
        multiply(vector, into: &result)
        return result
    }

    public func multiply(_ vector: [Double], into result: inout [Double]) {
        precondition(vector.count == columnCount, "Vector dimension does not match matrix")
        precondition(result.count == rowCount, "Result dimension does not match matrix")

        for row in 0..<rowCount {
            var sum = 0.0
            for index in rowStarts[row]..<rowStarts[row + 1] {
                let column = Int(columnIndices[index])
                sum += values[index] * vector[column]
            }
            result[row] = sum
        }

        guard isSymmetric else { return }

        // The lower triangle was multiplied above; mirror the off-diagonal
        // contributions into the upper triangle.
        for row in 0..<rowCount {
            for index in rowStarts[row]..<rowStarts[row + 1] {
                let column = Int(columnIndices[index])
                guard column != row else { continue }
                result[column] += values[index] * vector[row]
            }
        }
    }

    public func value(atRow row: Int, column: Int) -> Double {
        precondition((0..<rowCount).contains(row) && (0..<columnCount).contains(column), "Index out of range")

        var storedRow = row
        var storedColumn = column
        if isSymmetric, storedRow < storedColumn {
            swap(&storedRow, &storedColumn)
        }

        var low = rowStarts[storedRow]
        var high = rowStarts[storedRow + 1] - 1
        while low <= high {
            let middle = (low + high) / 2
            let candidate = Int(columnIndices[middle])
            if candidate == storedColumn {
                return values[middle]
            } else if candidate < storedColumn {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return 0
    }

    public var diagonal: [Double] {
        (0..<Swift.min(rowCount, columnCount)).map { value(atRow: $0, column: $0) }
    }

    /// Checks that every row has a structurally present, strictly positive
    /// diagonal entry. Factorization routines assume this.
    public func hasPositiveDiagonal() -> Bool {
        let diagonal = self.diagonal
        return !diagonal.isEmpty && diagonal.allSatisfy { $0.isFinite && $0 > 0 }
    }

    public func missingDiagonalRows() -> [Int] {
        (0..<Swift.min(rowCount, columnCount)).filter { value(atRow: $0, column: $0) <= 0 }
    }

    /// Dense expansion for debugging and small verification problems.
    public func toDense() -> DenseMatrix {
        var matrix = DenseMatrix(rows: rowCount, columns: columnCount)
        for row in 0..<rowCount {
            for index in rowStarts[row]..<rowStarts[row + 1] {
                let column = Int(columnIndices[index])
                matrix[row, column] = values[index]
                if isSymmetric, row != column {
                    matrix[column, row] = values[index]
                }
            }
        }
        return matrix
    }

    /// Converts the stored entries to coordinate form. Symmetric matrices emit
    /// only the lower triangle.
    public func coordinateTriplets() -> [SparseTriplet] {
        var triplets: [SparseTriplet] = []
        triplets.reserveCapacity(nonzeroCount)
        for row in 0..<rowCount {
            for index in rowStarts[row]..<rowStarts[row + 1] {
                triplets.append(SparseTriplet(
                    row: row,
                    column: Int(columnIndices[index]),
                    value: values[index]
                ))
            }
        }
        return triplets
    }
}
