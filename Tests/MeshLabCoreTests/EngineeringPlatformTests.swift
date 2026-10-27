import Foundation
import MeshLabCore
import Testing
import simd

private func qualificationProject() throws -> MeshLabProject {
    let mesh = try MeshGenerators.structuredRectangle(
        width: 2,
        height: 1,
        divisions: SIMD2(3, 2)
    )
    let material = try ElasticMaterial(
        youngModulus: 100e9,
        poissonRatio: 0.3,
        thickness: 0.1
    )
    let fixed = mesh.nodeIndices { abs($0.x) < 1e-12 }.map {
        DirichletCondition.fixed(node: $0)
    }
    let loaded = try #require(mesh.nodeIndices { abs($0.x - 2) < 1e-12 }.first)
    return MeshLabProject(
        name: "Qualification",
        mesh: mesh,
        material: material,
        constraints: fixed,
        loads: [.nodal(node: loaded, vector: SIMD3<Double>(0, -1_000, 0))],
        engineeringMetadata: EngineeringProjectMetadata(
            identifier: "ML-QA-001",
            revision: "B",
            analyst: "Verification",
            summary: "Static qualification case"
        )
    )
}

@Test func engineeringAssessmentProducesDeterministicPassingArtifact() throws {
    var project = try qualificationProject()
    let reference = try StaticAnalysis().solve(project.makeModel())
    project.engineeringRequirements = EngineeringRequirements(
        maximumDisplacement: 1.1 * reference.maxDisplacement,
        maximumVonMises: 1.1 * reference.maxVonMises,
        maximumRelativeResidual: 1e-8,
        minimumMeshQuality: 0.01
    )

    let artifact = try EngineeringAssessment.run(project)

    #expect(artifact.passed)
    #expect(artifact.projectIdentifier == "ML-QA-001")
    #expect(artifact.projectRevision == "B")
    #expect(artifact.analyst == "Verification")
    #expect(artifact.projectFingerprint == EngineeringAssessment.fingerprint(project))
    #expect(artifact.checks.allSatisfy { $0.status == .passed })
    #expect(try artifact.jsonData() == artifact.jsonData())
    let decoded = try JSONDecoder().decode(
        EngineeringRunArtifact.self,
        from: artifact.jsonData()
    )
    #expect(decoded == artifact)
    #expect(artifact.markdown().contains("Overall status: **PASS**"))
}

@Test func engineeringAssessmentFailsExceededAndUnavailableRequirements() throws {
    var project = try qualificationProject()
    let reference = try StaticAnalysis().solve(project.makeModel())
    project.engineeringRequirements = EngineeringRequirements(
        maximumDisplacement: 0.5 * reference.maxDisplacement,
        minimumFrequency: 1,
        maximumRelativeResidual: nil
    )

    let artifact = try EngineeringAssessment.run(project)

    #expect(!artifact.passed)
    #expect(artifact.checks.first {
        $0.kind == .maximumDisplacement
    }?.status == .failed)
    #expect(artifact.checks.first {
        $0.kind == .minimumFrequency
    }?.status == .notEvaluated)
    #expect(artifact.markdown().contains("Overall status: **FAIL**"))
}

@Test func engineeringAssessmentRejectsInvalidRequirements() throws {
    var project = try qualificationProject()
    project.engineeringRequirements.maximumVonMises = -1
    #expect(throws: EngineeringAssessmentError.self) {
        _ = try EngineeringAssessment.run(project)
    }
}

@Test func schemaElevenRoundTripsAndDefaultsUnitsFromVersionNine() throws {
    var project = try qualificationProject()
    project.engineeringRequirements.maximumDisplacement = 0.01
    let data = try MeshLabProjectFile.encode(project)
    let decoded = try MeshLabProjectFile.decode(data)
    #expect(decoded == project)
    #expect(decoded.schemaVersion == 11)

    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 9
    object.removeValue(forKey: "engineeringUnits")
    object.removeValue(forKey: "transientStudy")
    let migrated = try MeshLabProjectFile.decode(
        try JSONSerialization.data(withJSONObject: object)
    )
    #expect(migrated.schemaVersion == 9)
    #expect(migrated.engineeringUnits == .si)
    #expect(migrated.transientStudy == TransientStudy())
}

@Test func engineeringFingerprintChangesWithControlledProjectRevision() throws {
    let first = try qualificationProject()
    var second = first
    second.engineeringMetadata.revision = "C"
    #expect(EngineeringAssessment.fingerprint(first)
        != EngineeringAssessment.fingerprint(second))
}
