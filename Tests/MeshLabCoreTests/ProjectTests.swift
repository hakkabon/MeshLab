import Foundation
import Testing
import simd
@testable import MeshLabCore

@Test func projectRoundTripsThroughProjectFile() throws {
    let project = try MeshLabProject.cantileverExample()
    let data = try MeshLabProjectFile.encode(project)
    let decoded = try MeshLabProjectFile.decode(data)
    #expect(decoded == project)
    #expect(decoded.schemaVersion == MeshLabProject.currentSchemaVersion)
    #expect(!decoded.mesh.nodes.isEmpty)
    #expect(!decoded.constraints.isEmpty)
}

@Test func projectAppliesLoadScaleToLoadsAndBodyForce() throws {
    var project = try MeshLabProject.cantileverExample()
    project.loadScale = 2.5
    project.bodyForce = SIMD3<Double>(0, 0, -10)
    let model = project.makeModel()

    #expect(model.loads.count == project.loads.count)
    #expect(model.bodyForce == SIMD3<Double>(0, 0, -25))
    if case .nodal(_, let vector) = model.loads.first {
        #expect(vector.z == -25_000)
    } else {
        Issue.record("Expected nodal loads in the cantilever example")
    }
}

@Test func projectRejectsFutureSchemaVersion() throws {
    let project = try MeshLabProject.cantileverExample()
    let data = try MeshLabProjectFile.encode(project)
    var object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["schemaVersion"] = MeshLabProject.currentSchemaVersion + 1
    let futureData = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: MeshLabProjectError.self) {
        try MeshLabProjectFile.decode(futureData)
    }
}

@Test func resultCSVContainsEveryNodeAndHeader() throws {
    let project = try MeshLabProject.cantileverExample()
    let result = try StaticAnalysis(options: project.makeAnalysisOptions())
        .solve(project.makeModel())
    let csv = AnalysisResultExport.csv(project: project, result: result)
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

    #expect(lines.first == "node,x,y,z,ux,uy,uz,vonMises")
    #expect(lines.count == project.mesh.nodes.count + 2)
    #expect(lines[1].hasPrefix("0,"))
}

@Test func projectRoundTripsSolverConfiguration() throws {
    var project = try MeshLabProject.cantileverExample()
    project.solverMethod = .gmres(
        restart: 25,
        settings: SparseIterativeSettings(
            maxIterations: 321,
            tolerance: 1e-9,
            initialSolution: [1, 2, 3],
            preconditioner: .ilu0
        )
    )
    project.directSettings = SparseDirectSettings(
        ordering: .natural,
        pivotTolerance: 1e-10,
        dropTolerance: 1e-14,
        refinementSteps: 2,
        refinementTolerance: 1e-11
    )
    let decoded = try MeshLabProjectFile.decode(
        try MeshLabProjectFile.encode(project)
    )
    #expect(decoded.solverMethod == project.solverMethod)
    #expect(decoded.directSettings == project.directSettings)
    #expect(decoded.showStress == project.showStress)
    #expect(decoded.deformationScale == project.deformationScale)
}
