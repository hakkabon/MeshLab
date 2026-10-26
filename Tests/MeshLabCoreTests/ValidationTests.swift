import MeshLabCore
import Testing

@Test func standardValidationSuitePassesAndSerializesDeterministically() throws {
    let report = try MeshLabValidation.runStandardSuite()

    #expect(report.passed)
    #expect(report.cases.map(\.identifier) == [
        "operator-contract-2x2",
        "cantilever-assembled-matrix-free",
        "linear-thermal-bar",
        "structured-mesh-quality",
    ])
    #expect(try report.jsonData() == report.jsonData())
}
