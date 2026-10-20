import Testing
@testable import MeshLabCore

private func smallSymmetricMatrix(scale: Double = 1) throws -> SparseMatrix {
    try SparseMatrix.symmetric(size: 3, lowerTriplets: [
        SparseTriplet(row: 0, column: 0, value: 4 * scale),
        SparseTriplet(row: 1, column: 0, value: 1 * scale),
        SparseTriplet(row: 1, column: 1, value: 3 * scale),
        SparseTriplet(row: 2, column: 1, value: 1 * scale),
        SparseTriplet(row: 2, column: 2, value: 2 * scale),
    ])
}

@Test func numericCoreDirectFactorizationsSolveAndReportDiagnostics() throws {
    let matrix = try smallSymmetricMatrix()
    let rhs = [1.0, 2.0, 3.0]

    let lu = try SparseSolver(matrix: matrix, method: .numericCoreLU)
    let luReport = try lu.solveWithReport(rhs)
    #expect(luReport.converged)
    #expect(luReport.backwardError != nil)
    #expect(luReport.refinementSteps != nil)
    #expect(luReport.factorNonZeroCount != nil)

    let ldlt = try SparseSolver(matrix: matrix, method: .numericCoreLDLT)
    let ldltReport = try ldlt.solveWithReport(rhs)
    #expect(ldltReport.converged)
    #expect(ldltReport.inertia == SparseInertiaReport(positive: 3, negative: 0, zero: 0))

    let residual = matrix.multiply(ldltReport.solution)
    for index in rhs.indices {
        #expect(abs(residual[index] - rhs[index]) < 1e-12)
    }
}

@Test func numericCoreLUReusesFactorizationAndRejectsPatternChanges() throws {
    let solver = try SparseSolver(matrix: smallSymmetricMatrix(), method: .numericCoreLU)
    let rhs = [1.0, 2.0, 3.0]
    let first = try solver.solveWithReport(rhs)
    #expect(first.converged)

    try solver.refactor(with: smallSymmetricMatrix(scale: 2))
    let second = try solver.solveWithReport(rhs)
    let residual = try smallSymmetricMatrix(scale: 2).multiply(second.solution)
    for index in rhs.indices {
        #expect(abs(residual[index] - rhs[index]) < 1e-12)
    }

    let changedPattern = try SparseMatrix.symmetric(size: 3, lowerTriplets: [
        SparseTriplet(row: 0, column: 0, value: 4),
        SparseTriplet(row: 1, column: 1, value: 3),
        SparseTriplet(row: 2, column: 2, value: 2),
    ])
    #expect(throws: SparseSolverError.self) {
        try solver.refactor(with: changedPattern)
    }
}

@Test func numericCoreLDLTRequiresSymmetricMatrix() throws {
    let matrix = try SparseMatrix(rows: 2, columns: 2, triplets: [
        SparseTriplet(row: 0, column: 0, value: 2),
        SparseTriplet(row: 0, column: 1, value: 1),
        SparseTriplet(row: 1, column: 1, value: 2),
    ])
    #expect(throws: SparseSolverError.self) {
        _ = try SparseSolver(matrix: matrix, method: .numericCoreLDLT)
    }
}

@Test func numericCoreLDLTReportsIndefiniteInertia() throws {
    let matrix = try SparseMatrix.symmetric(size: 3, lowerTriplets: [
        SparseTriplet(row: 0, column: 0, value: 2),
        SparseTriplet(row: 1, column: 1, value: -3),
        SparseTriplet(row: 2, column: 2, value: 4),
    ])
    let solver = try SparseSolver(
        matrix: matrix,
        method: .numericCoreLDLT,
        directSettings: SparseDirectSettings(ordering: .natural)
    )
    let report = try solver.solveWithReport([1, 2, 3])
    #expect(report.inertia == SparseInertiaReport(positive: 2, negative: 1, zero: 0))
}
