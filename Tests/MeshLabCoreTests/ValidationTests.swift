import Foundation
import MeshLabCore
import Testing

@Test func standardValidationSuitePassesAndSerializesDeterministically() throws {
    let report = try MeshLabValidation.runStandardSuite()

    #expect(report.passed)
    #expect(report.cases.map(\.identifier) == [
        "operator-contract-2x2",
        "tet4-element-kernel-contract",
        "cantilever-assembled-matrix-free",
        "prepared-linear-factorization-reuse",
        "linear-thermal-bar",
        "structured-mesh-quality",
        "finite-strain-small-load",
        "constrained-parametric-pareto",
        "qualified-static-artifact",
    ])
    #expect(try report.jsonData() == report.jsonData())
    #expect(report.compare(to: report).passed)
}

@Test func validationBaselineFailsClosedOnStackDrift() throws {
    let report = try MeshLabValidation.runStandardSuite()
    var object = try #require(
        try JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any]
    )
    var stack = try #require(object["numericStack"] as? [String: Any])
    stack["rustNumericCoreVersion"] = "different"
    object["numericStack"] = stack
    let baseline = try JSONDecoder().decode(
        ValidationReport.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    let comparison = report.compare(to: baseline)
    #expect(!comparison.passed)
    #expect(comparison.issues.contains { $0.path == "numericStack" })
}
