import Foundation
import MeshLabCore
import Testing
import simd

private func transientThermalFixture() throws -> (Mesh, ElasticMaterial) {
    let mesh = try MeshGenerators.structuredBox(
        size: SIMD3<Double>(1, 1, 1),
        divisions: SIMD3<Int>(1, 1, 2)
    )
    let material = try ElasticMaterial(
        youngModulus: 1e7,
        poissonRatio: 0.3,
        density: 1_000,
        thermalConductivity: 10,
        thermalExpansion: 1e-5
    )
    return (mesh, material)
}

@Test func implicitTransientHeatConductionCoolsAndReusesTimeGrid() throws {
    let (mesh, material) = try transientThermalFixture()
    let fixed = mesh.nodeIndices { abs($0.z) < 1e-12 }
        .map { ThermalConstraint(node: $0, temperature: 0) }
    let model = ThermalModel(mesh: mesh, material: material, constraints: fixed)
    let initial = mesh.nodes.map { $0.z == 0 ? 0.0 : 100.0 }
    let result = try TransientThermalAnalysis(options: TransientThermalOptions(
        timeStep: 0.1,
        steps: 4,
        volumetricHeatCapacity: 100,
        theta: 1
    )).solve(model, initialTemperature: initial)

    #expect(result.states.count == 5)
    #expect(result.states.last!.time == 0.4)
    #expect(result.states.last!.thermalEnergy < result.states.first!.thermalEnergy)
    #expect(result.states.last!.maximumTemperature > 0)
    #expect(result.maximumRelativeResidual < 1e-10)
}

@Test func transientThermoMechanicsCarriesTemperatureIntoNewmarkStates() throws {
    var project = try MeshLabProject.cantileverExample()
    project.transientStudy = TransientStudy(
        timeStep: 0.01,
        steps: 2,
        loadFactors: [0, 0, 0],
        thermalCoupling: true,
        volumetricHeatCapacity: 3.5e6,
        heatFactors: [1, 1, 1],
        initialTemperature: [Double](
            repeating: project.thermalStudy.referenceTemperature,
            count: project.mesh.nodes.count
        )
    )
    let result = try TransientThermoMechanicalAnalysis(
        thermalOptions: project.makeTransientThermalOptions(),
        structuralOptions: project.makeTransientOptions(),
        analysisOptions: project.makeAnalysisOptions(),
        referenceTemperature: project.thermalStudy.referenceTemperature
    ).solve(
        thermal: project.makeThermalModel(),
        structural: project.makeModel(),
        loadHistory: project.makeTransientLoadHistory(),
        heatFactors: project.makeTransientHeatFactors(),
        initialTemperature: project.transientStudy.initialTemperature
    )

    #expect(result.thermal.states.count == 3)
    #expect(result.structural.states.count == 3)
    #expect(result.structural.states.allSatisfy { $0.temperatures?.count == project.mesh.nodes.count })
    #expect(result.structural.states.last!.displacement.contains { simd_length($0) > 0 })
}

@Test func schemaThirteenPersistsTransientMultiphysicsAndMigratesTwelve() throws {
    var project = try MeshLabProject.cantileverExample()
    project.transientStudy = TransientStudy(
        timeStep: 0.2,
        steps: 3,
        thermalCoupling: true,
        volumetricHeatCapacity: 4.2e6,
        thermalTheta: 0.5,
        heatFactors: [0, 0.5, 1, 1],
        initialTemperature: [20]
    )
    let encoded = try MeshLabProjectFile.encode(project)
    let decoded = try MeshLabProjectFile.decode(encoded)
    #expect(decoded.schemaVersion == MeshLabProject.currentSchemaVersion)
    #expect(decoded.transientStudy == project.transientStudy)

    var object = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["schemaVersion"] = 12
    var transient = try #require(object["transientStudy"] as? [String: Any])
    transient.removeValue(forKey: "thermalCoupling")
    transient.removeValue(forKey: "volumetricHeatCapacity")
    transient.removeValue(forKey: "thermalTheta")
    transient.removeValue(forKey: "heatFactors")
    transient.removeValue(forKey: "initialTemperature")
    object["transientStudy"] = transient
    let migrated = try MeshLabProjectFile.decode(
        JSONSerialization.data(withJSONObject: object)
    )
    #expect(migrated.schemaVersion == 12)
    #expect(!migrated.transientStudy.thermalCoupling)
    #expect(migrated.transientStudy.volumetricHeatCapacity == 3.5e6)
}
