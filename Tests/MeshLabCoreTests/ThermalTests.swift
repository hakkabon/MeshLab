import Foundation
import Testing
import simd
@testable import MeshLabCore

private func thermalBar() throws -> (mesh: Mesh, material: ElasticMaterial) {
    let mesh = try MeshGenerators.structuredBox(
        size: SIMD3<Double>(1, 1, 4),
        divisions: SIMD3<Int>(1, 1, 8)
    )
    let material = try ElasticMaterial(
        youngModulus: 200e9,
        poissonRatio: 0.3,
        density: 7800,
        thermalConductivity: 50,
        thermalExpansion: 1.2e-5
    )
    return (mesh, material)
}

@Test func thermalConductionReproducesLinearTemperatureAndFlux() throws {
    let (mesh, material) = try thermalBar()
    let constraints = mesh.nodeIndices { abs($0.z) < 1e-12 }
        .map { ThermalConstraint(node: $0, temperature: 0) }
        + mesh.nodeIndices { abs($0.z - 4) < 1e-12 }
        .map { ThermalConstraint(node: $0, temperature: 100) }
    let model = ThermalModel(
        mesh: mesh,
        material: material,
        constraints: constraints
    )
    let result = try ThermalAnalysis().solve(model)

    for node in mesh.nodes.indices {
        let expected = 25 * mesh.nodes[node].z
        #expect(abs(result.temperatures[node] - expected) < 1e-9)
    }
    #expect(result.elementHeatFluxes.allSatisfy {
        abs($0.vector.z + material.thermalConductivity * 25) < 1e-8
            && abs($0.vector.x) < 1e-8
            && abs($0.vector.y) < 1e-8
    })
    #expect(result.maximumTemperature == 100)
}

@Test func thermalExpansionIsStressFreeWhenUnrestrained() throws {
    let (mesh, material) = try thermalBar()
    var constraints = mesh.nodeIndices { abs($0.z) < 1e-12 }
        .map { DirichletCondition(node: $0, axis: 2, value: 0) }
    let origin = try #require(mesh.nodeIndices {
        abs($0.x) < 1e-12 && abs($0.y) < 1e-12 && abs($0.z) < 1e-12
    }.first)
    constraints.append(DirichletCondition(node: origin, axis: 0, value: 0))
    constraints.append(DirichletCondition(node: origin, axis: 1, value: 0))
    let xAxis = try #require(mesh.nodeIndices {
        abs($0.x - 1) < 1e-12 && abs($0.y) < 1e-12 && abs($0.z) < 1e-12
    }.first)
    constraints.append(DirichletCondition(node: xAxis, axis: 1, value: 0))
    let mechanical = FEMModel(
        mesh: mesh,
        material: material,
        constraints: constraints
    )
    let change = 80.0
    let result = try ThermalStressAnalysis(options: AnalysisOptions(solverMethod: .numericCoreLDLT), referenceTemperature: 20).solve(
        mechanical,
        temperatures: Array(repeating: 20 + change, count: mesh.nodes.count)
    )

    let tip = try #require(mesh.nodeIndices { abs($0.z - 4) < 1e-12 }.first)
    let scale = material.thermalExpansion * change
    let expected = mesh.nodes[tip] * SIMD3<Double>(repeating: scale)
    let actual = result.staticResult.displacements[tip]
    #expect(abs(actual.x - expected.x) < 1e-12)
    #expect(abs(actual.y - expected.y) < 1e-12)
    #expect(abs(actual.z - expected.z) < 1e-12)
    #expect(result.staticResult.maxVonMises < 1e-3)
}

@Test func fullyFixedThermalExpansionProducesUniformCompression() throws {
    let mesh = try MeshGenerators.structuredBox(
        size: SIMD3<Double>(1, 1, 1),
        divisions: SIMD3<Int>(2, 2, 2)
    )
    let material = try ElasticMaterial(
        youngModulus: 200e9,
        poissonRatio: 0.3,
        density: 7800,
        thermalConductivity: 50,
        thermalExpansion: 1.2e-5
    )
    let boundary = mesh.nodeIndices { point in
        point.x == 0 || point.x == 1
            || point.y == 0 || point.y == 1
            || point.z == 0 || point.z == 1
    }
    let constraints = boundary.map { DirichletCondition.fixed(node: $0) }
    let mechanical = FEMModel(
        mesh: mesh,
        material: material,
        constraints: constraints
    )
    let change = 100.0
    let result = try ThermalStressAnalysis().solve(
        mechanical,
        temperatures: Array(repeating: change, count: mesh.nodes.count)
    )

    let expected = -(3 * material.lameLambda + 2 * material.shearModulus)
        * material.thermalExpansion * change
    for stress in result.staticResult.elementStresses {
        #expect(abs(stress.components[0] - expected) < abs(expected) * 1e-8)
        #expect(abs(stress.components[1] - expected) < abs(expected) * 1e-8)
        #expect(abs(stress.components[2] - expected) < abs(expected) * 1e-8)
        #expect(abs(stress.components[3]) < abs(expected) * 1e-8)
        #expect(abs(stress.components[4]) < abs(expected) * 1e-8)
        #expect(abs(stress.components[5]) < abs(expected) * 1e-8)
    }
}

@Test func thermalAnalysisRejectsMissingConductivity() throws {
    let (mesh, _) = try thermalBar()
    let material = try ElasticMaterial(youngModulus: 200e9, poissonRatio: 0.3)
    let model = ThermalModel(
        mesh: mesh,
        material: material,
        constraints: [ThermalConstraint(node: 0, temperature: 0)]
    )
    #expect(throws: FEMError.self) {
        _ = try ThermalAnalysis().solve(model)
    }
}
