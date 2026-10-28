import Foundation
import Testing
import simd
@testable import MeshLabCore

private func p11bTetra(load: Double, modulus: Double = 1e7) throws -> FEMModel {
    let mesh = try Mesh(
        nodes: [
            SIMD3<Double>(0, 0, 0), SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, 0, 1),
        ],
        elements: [Element(type: .tetrahedron4, nodes: [0, 1, 2, 3])]
    )
    return FEMModel(
        mesh: mesh,
        material: try ElasticMaterial(youngModulus: modulus, poissonRatio: 0.3),
        constraints: [
            .fixed(node: 0),
            .fixed(node: 1, axis: 1), .fixed(node: 1, axis: 2),
            .fixed(node: 2, axis: 2),
        ],
        loads: [.nodal(node: 3, vector: SIMD3<Double>(0, 0, load))]
    )
}

@Test func adaptiveNonlinearSteppingGrowsEasyIncrements() throws {
    let result = try NonlinearStaticAnalysis(options: NonlinearStaticOptions(
        loadSteps: 8,
        maximumNewtonIterations: 20,
        residualTolerance: 1e-9,
        targetNewtonIterations: 10
    )).solve(p11bTetra(load: 10))

    #expect(result.loadSteps.count < 8)
    #expect(result.loadSteps.last?.loadFactor == 1)
    #expect(result.loadSteps.allSatisfy { $0.loadIncrement > 0 })
}

@Test func neoHookeanMatchesLinearResponseAtSmallStrain() throws {
    let model = try p11bTetra(load: 10)
    let linear = try StaticAnalysis().solve(model)
    let nonlinear = try NonlinearStaticAnalysis(options: NonlinearStaticOptions(
        loadSteps: 2,
        residualTolerance: 1e-10,
        constitutiveModel: .neoHookean
    )).solve(model)

    #expect(abs(nonlinear.staticResult.maxDisplacement - linear.maxDisplacement)
        / linear.maxDisplacement < 1e-4)
    #expect(nonlinear.staticResult.equilibrium.relativeFreeResidual < 1e-8)
}

@Test func j2PlasticityCommitsHistoryAfterYield() throws {
    let result = try NonlinearStaticAnalysis(options: NonlinearStaticOptions(
        loadSteps: 8,
        maximumNewtonIterations: 30,
        residualTolerance: 1e-8,
        constitutiveModel: .j2Plasticity,
        yieldStress: 1_000,
        hardeningModulus: 50_000
    )).solve(p11bTetra(load: 2_000))

    let state = try #require(result.elementStates.first)
    #expect(state.values.count == 7)
    #expect(state.values[6] > 0)
    #expect(result.staticResult.maxVonMises > 1_000)
}

@Test func frictionlessPlaneContactLimitsPenetration() throws {
    let model = try p11bTetra(load: -100_000, modulus: 1e7)
    let free = try NonlinearStaticAnalysis(options: NonlinearStaticOptions(
        loadSteps: 10,
        maximumNewtonIterations: 30
    )).solve(model)
    let contacted = try NonlinearStaticAnalysis(options: NonlinearStaticOptions(
        loadSteps: 10,
        maximumNewtonIterations: 30,
        contacts: [NonlinearContactPlane(
            nodes: [3],
            point: SIMD3<Double>(0, 0, 0.99),
            normal: SIMD3<Double>(0, 0, 1),
            penalty: 1e8
        )]
    )).solve(model)

    let freeZ = 1 + free.staticResult.displacements[3].z
    let contactZ = 1 + contacted.staticResult.displacements[3].z
    #expect(freeZ < 0.99)
    #expect(contactZ > freeZ)
    #expect(contactZ > 0.988)
    #expect(contacted.staticResult.equilibrium.relativeFreeResidual < 1e-7)
    #expect(simd_length(contacted.staticResult.equilibrium.forceImbalance) < 1e-4)
}

@Test func schemaTwelvePersistsNonlinearProductionOptions() throws {
    var project = try MeshLabProject.cantileverExample()
    project.nonlinearOptions = NonlinearStaticOptions(
        constitutiveModel: .neoHookean,
        contacts: [NonlinearContactPlane(
            nodes: [0], point: .zero, normal: SIMD3(0, 0, 1), penalty: 1e8
        )]
    )
    let data = try MeshLabProjectFile.encode(project)
    let decoded = try MeshLabProjectFile.decode(data)
    #expect(decoded == project)
    #expect(decoded.schemaVersion == MeshLabProject.currentSchemaVersion)

    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 11
    if var nonlinear = object["nonlinearOptions"] as? [String: Any] {
        for key in [
            "adaptiveStepping", "minimumLoadIncrement", "maximumLoadIncrement",
            "stepGrowthFactor", "stepCutbackFactor", "targetNewtonIterations",
            "maximumStepRetries", "constitutiveModel", "yieldStress",
            "hardeningModulus", "contacts",
        ] { nonlinear.removeValue(forKey: key) }
        object["nonlinearOptions"] = nonlinear
    }
    let migrated = try MeshLabProjectFile.decode(
        try JSONSerialization.data(withJSONObject: object)
    )
    #expect(migrated.nonlinearOptions.constitutiveModel == .saintVenantKirchhoff)
    #expect(!migrated.nonlinearOptions.adaptiveStepping)
    #expect(migrated.nonlinearOptions.contacts.isEmpty)
}
