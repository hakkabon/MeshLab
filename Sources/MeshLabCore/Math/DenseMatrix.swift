import Accelerate

/// A dense, column-major matrix backed by BLAS.
///
/// The element and assembly code in this package uses fixed-size local
/// matrices, but `DenseMatrix` is useful for material transformations,
/// debugging, and moderate-sized dense systems. Large systems should use
/// ``SparseMatrix`` instead.
public struct DenseMatrix: Sendable, Equatable {
    public let rows: Int
    public let columns: Int
    public private(set) var values: [Double]

    public init(rows: Int, columns: Int, values: [Double]) {
        precondition(rows >= 0 && columns >= 0, "Matrix dimensions must be non-negative")
        precondition(values.count == rows * columns, "Value count does not match dimensions")
        self.rows = rows
        self.columns = columns
        self.values = values
    }

    public init(rows: Int, columns: Int, repeating value: Double = 0) {
        precondition(rows >= 0 && columns >= 0, "Matrix dimensions must be non-negative")
        self.rows = rows
        self.columns = columns
        self.values = [Double](repeating: value, count: rows * columns)
    }

    public init(rowMajor values: [Double], rows: Int, columns: Int) {
        precondition(values.count == rows * columns, "Value count does not match dimensions")
        var columnMajor = [Double](repeating: 0, count: values.count)
        for row in 0..<rows {
            for column in 0..<columns {
                columnMajor[column * rows + row] = values[row * columns + column]
            }
        }
        self.init(rows: rows, columns: columns, values: columnMajor)
    }

    public static func identity(_ size: Int) -> DenseMatrix {
        var matrix = DenseMatrix(rows: size, columns: size)
        for index in 0..<size {
            matrix[index, index] = 1
        }
        return matrix
    }

    public subscript(_ row: Int, _ column: Int) -> Double {
        get {
            precondition((0..<rows).contains(row) && (0..<columns).contains(column), "Index out of range")
            return values[column * rows + row]
        }
        set {
            precondition((0..<rows).contains(row) && (0..<columns).contains(column), "Index out of range")
            values[column * rows + row] = newValue
        }
    }

    public var transpose: DenseMatrix {
        var result = DenseMatrix(rows: columns, columns: rows)
        for column in 0..<columns {
            for row in 0..<rows {
                result[column, row] = self[row, column]
            }
        }
        return result
    }

    /// Matrix-matrix product using Accelerate BLAS.
    public func multiplied(by other: DenseMatrix) -> DenseMatrix {
        precondition(columns == other.rows, "Inner dimensions must match")
        var result = DenseMatrix(rows: rows, columns: other.columns)
        cblas_dgemm(
            CblasColMajor,
            CblasNoTrans,
            CblasNoTrans,
            Int32(rows),
            Int32(other.columns),
            Int32(columns),
            1,
            values,
            Int32(rows),
            other.values,
            Int32(other.rows),
            0,
            &result.values,
            Int32(rows)
        )
        return result
    }

    /// Matrix-vector product using Accelerate BLAS.
    public func multiplied(by vector: [Double]) -> [Double] {
        precondition(columns == vector.count, "Matrix and vector dimensions must match")
        var result = [Double](repeating: 0, count: rows)
        cblas_dgemv(
            CblasColMajor,
            CblasNoTrans,
            Int32(rows),
            Int32(columns),
            1,
            values,
            Int32(rows),
            vector,
            1,
            0,
            &result,
            1
        )
        return result
    }

    public static func * (lhs: DenseMatrix, rhs: DenseMatrix) -> DenseMatrix {
        lhs.multiplied(by: rhs)
    }

    public static func * (lhs: DenseMatrix, rhs: [Double]) -> [Double] {
        lhs.multiplied(by: rhs)
    }

    public var diagonal: [Double] {
        let count = Swift.min(rows, columns)
        return (0..<count).map { self[$0, $0] }
    }

    /// Converts the matrix to row-major order for APIs that expect it.
    public func rowMajorValues() -> [Double] {
        var result = [Double](repeating: 0, count: values.count)
        for column in 0..<columns {
            for row in 0..<rows {
                result[row * columns + column] = values[column * rows + row]
            }
        }
        return result
    }
}
