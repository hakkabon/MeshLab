import Testing
import simd
@testable import MeshLabCore

@Test func vectorOperations() {
    let a = [1.0, 2.0, 3.0]
    let b = [4.0, 5.0, 6.0]

    #expect(VectorMath.add(a, b) == [5, 7, 9])
    #expect(VectorMath.subtract(a, b) == [-3, -3, -3])
    #expect(VectorMath.multiply(a, b) == [4, 10, 18])
    #expect(VectorMath.scale(a, by: 2) == [2, 4, 6])
    #expect(VectorMath.addScaled(a, b, alpha: 2) == [9, 12, 15])
    #expect(abs(VectorMath.dot(a, b) - 32) < 1e-12)
    #expect(abs(VectorMath.norm([3, 4]) - 5) < 1e-12)
    #expect(VectorMath.sum(a) == 6)
    #expect(VectorMath.sqrt([1, 4, 9]) == [1, 2, 3])
    #expect(VectorMath.clip([-1, 0.5, 2], to: 0...1) == [0, 0.5, 1])
}

@Test func denseMatrixProducts() {
    let a = DenseMatrix(
        rows: 2,
        columns: 3,
        values: [1, 2, 3, 4, 5, 6]
    )
    let b = DenseMatrix(
        rows: 3,
        columns: 2,
        values: [1, 2, 3, 4, 5, 6]
    )
    let product = a * b
    #expect(product[0, 0] == 22)
    #expect(product[0, 1] == 49)
    #expect(product[1, 0] == 28)
    #expect(product[1, 1] == 64)
    #expect(a * [1, 1, 1] == [9, 12])
}

@Test func sparseMatrixAssemblesAndMultiplies() throws {
    let triplets = [
        SparseTriplet(row: 0, column: 0, value: 2),
        SparseTriplet(row: 0, column: 1, value: 1),
        SparseTriplet(row: 0, column: 1, value: 1),
        SparseTriplet(row: 1, column: 1, value: 3),
        SparseTriplet(row: 1, column: 0, value: 4),
    ]
    let matrix = try SparseMatrix(rows: 2, columns: 2, triplets: triplets)
    #expect(matrix.value(atRow: 0, column: 0) == 2)
    #expect(matrix.value(atRow: 0, column: 1) == 2)
    #expect(matrix.value(atRow: 1, column: 0) == 4)
    #expect(matrix.value(atRow: 1, column: 1) == 3)
    #expect(matrix.multiply([1, 2]) == [6, 10])
}

@Test func symmetricSparseMatrixMirrorsUpperTriangle() throws {
    let matrix = try SparseMatrix.symmetric(
        size: 2,
        lowerTriplets: [
            SparseTriplet(row: 0, column: 0, value: 4),
            SparseTriplet(row: 1, column: 0, value: 1),
            SparseTriplet(row: 1, column: 1, value: 3),
        ]
    )
    #expect(matrix.value(atRow: 0, column: 1) == 1)
    #expect(matrix.multiply([1, 2]) == [6, 7])
    #expect(matrix.toDense()[0, 1] == 1)
}

@Test func sparseSolverBackendsAgree() throws {
    let matrix = try SparseMatrix.symmetric(
        size: 3,
        lowerTriplets: [
            SparseTriplet(row: 0, column: 0, value: 4),
            SparseTriplet(row: 1, column: 0, value: 1),
            SparseTriplet(row: 1, column: 1, value: 3),
            SparseTriplet(row: 2, column: 0, value: 0.5),
            SparseTriplet(row: 2, column: 2, value: 2),
        ]
    )
    let rhs = [1.0, 2.0, 3.0]

    let accelerate = try SparseSolver(matrix: matrix, method: .accelerateCholesky)
    let expected = try accelerate.solve(rhs)

    for method in [
        SparseSolverMethod.numericCoreCholesky,
        .numericCoreLU,
        .conjugateGradient(.init(maxIterations: 100, tolerance: 1e-12)),
    ] {
        let solver = try SparseSolver(matrix: matrix, method: method)
        let actual = try solver.solve(rhs)
        for index in expected.indices {
            #expect(abs(actual[index] - expected[index]) < 1e-8)
        }
    }
}

@Test func sparseSolverRejectsEmptyMatrix() {
    let empty = try! SparseMatrix(rows: 2, columns: 2, triplets: [])
    #expect(throws: SparseSolverError.self) {
        _ = try SparseSolver(matrix: empty)
    }
}
