import Foundation
import Testing
import simd
@testable import MeshLabCore

private let unitHexNodes = [
    SIMD3<Double>(0, 0, 0), SIMD3<Double>(1, 0, 0),
    SIMD3<Double>(1, 1, 0), SIMD3<Double>(0, 1, 0),
    SIMD3<Double>(0, 0, 1), SIMD3<Double>(1, 0, 1),
    SIMD3<Double>(1, 1, 1), SIMD3<Double>(0, 1, 1),
]

private let quadraticTetNodes = [
    SIMD3<Double>(0, 0, 0), SIMD3<Double>(1, 0, 0),
    SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, 0, 1),
    SIMD3<Double>(0.5, 0, 0), SIMD3<Double>(0.5, 0.5, 0),
    SIMD3<Double>(0, 0.5, 0), SIMD3<Double>(0, 0, 0.5),
    SIMD3<Double>(0.5, 0, 0.5), SIMD3<Double>(0, 0.5, 0.5),
]

@Test func higherOrderSolidsPassConstantStrainAndMassChecks() throws {
    let material = try ElasticMaterial(
        youngModulus: 1000, poissonRatio: 0.25, density: 3
    )
    for (type, nodes, expectedMeasure) in [
        (ElementType.hexahedron8, unitHexNodes, 1.0),
        (ElementType.tetrahedron10, quadraticTetNodes, 1.0 / 6.0),
    ] {
        let mesh = try Mesh(nodes: nodes, elements: [Element(
            type: type, nodes: Array(nodes.indices)
        )])
        let data = try ElementKinematics.compute(
            mesh: mesh, material: material, elementIndex: 0
        )
        let displacement = nodes.flatMap { [$0.x * 0.01, $0.y * -0.02, $0.z * 0.03] }
        let stress = data.stress(localDisplacement: displacement)
        let expected = material.constitutiveMatrix(for: 3)
        let strain = [0.01, -0.02, 0.03, 0, 0, 0]
        for row in 0..<6 {
            let exact = (0..<6).reduce(0.0) { $0 + expected[row * 6 + $1] * strain[$1] }
            #expect(abs(stress[row] - exact) < 1e-9)
        }
        #expect(abs(data.measure - expectedMeasure) < 1e-12)
        let totalMassTerms = data.mass(density: material.density).reduce(0, +)
        #expect(abs(totalMassTerms - 3 * material.density * expectedMeasure) < 1e-10)
    }
}

@Test func higherOrderSolidSurfacesAreTriangulated() throws {
    let hex = try Mesh(
        nodes: unitHexNodes,
        elements: [Element(type: .hexahedron8, nodes: Array(0..<8))]
    )
    let tet = try Mesh(
        nodes: quadraticTetNodes,
        elements: [Element(type: .tetrahedron10, nodes: Array(0..<10))]
    )
    #expect(try hex.makeSurfaceMesh().indices.count == 12 * 3)
    #expect(try tet.makeSurfaceMesh().indices.count == 16 * 3)
}

@Test func pressureLoadPreservesIntegratedResultant() throws {
    let mesh = try Mesh(
        nodes: unitHexNodes,
        elements: [Element(type: .hexahedron8, nodes: Array(0..<8))]
    )
    let material = try ElasticMaterial(youngModulus: 1, poissonRatio: 0.25)
    let model = FEMModel(
        mesh: mesh,
        material: material,
        constraints: [],
        loads: [.pressure(nodes: [4, 5, 6, 7], magnitude: 12)]
    )
    let load = try FEMAssembly.loadVector(model)
    let resultant = stride(from: 0, to: load.count, by: 3).reduce(SIMD3<Double>.zero) {
        $0 + SIMD3(load[$1], load[$1 + 1], load[$1 + 2])
    }
    #expect(simd_length(resultant - SIMD3<Double>(0, 0, -12)) < 1e-12)
}

@Test func convectionProvidesAWellPosedThermalReference() throws {
    let mesh = try Mesh(
        nodes: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
        elements: [Element(type: .triangle3, nodes: [0, 1, 2])]
    )
    let material = try ElasticMaterial(
        youngModulus: 1, poissonRatio: 0.25, thermalConductivity: 10
    )
    let result = try ThermalAnalysis().solve(ThermalModel(
        mesh: mesh,
        material: material,
        constraints: [],
        nodalHeat: (0..<3).map { ThermalLoad(node: $0, value: 10) },
        surfaceConditions: [.convection(
            nodes: [0, 1, 2], coefficient: 2, ambientTemperature: 300
        )]
    ))
    for temperature in result.temperatures {
        #expect(abs(temperature - 330) < 1e-8)
    }
}

@Test func sparseModalMatchesDenseLowestModes() throws {
    let mesh = try MeshGenerators.structuredBox(
        size: SIMD3<Double>(1, 1, 4), divisions: SIMD3<Int>(1, 1, 5)
    )
    let material = try ElasticMaterial(
        youngModulus: 200e9, poissonRatio: 0.3, density: 7800
    )
    var constraints: [DirichletCondition] = []
    for node in mesh.nodes.indices {
        constraints.append(.fixed(node: node, axis: 0))
        constraints.append(.fixed(node: node, axis: 1))
        if mesh.nodes[node].z == 0 { constraints.append(.fixed(node: node, axis: 2)) }
    }
    let model = FEMModel(mesh: mesh, material: material, constraints: constraints)
    let dense = try ModalAnalysis(options: ModalOptions(
        modeCount: 2, solver: .dense
    )).solve(model)
    let sparse = try ModalAnalysis(options: ModalOptions(
        modeCount: 2, solver: .sparseSubspace, maximumIterations: 120
    )).solve(model)
    for index in 0..<2 {
        #expect(abs(dense.frequenciesHz[index] - sparse.frequenciesHz[index])
            / dense.frequenciesHz[index] < 1e-6)
    }
}

@Test func modernInterchangeAndGmshHigherOrderRoundTripCoverage() throws {
    let mesh = try Mesh(
        nodes: unitHexNodes,
        elements: [Element(type: .hexahedron8, nodes: Array(0..<8))]
    )
    #expect(VTUExporter.string(mesh: mesh).contains(">12</DataArray>"))
    #expect(try XDMFExporter.string(mesh: mesh).contains("TopologyType=\"Hexahedron\""))

    let nodeLines = unitHexNodes.enumerated().map {
        "\($0.offset + 1) \($0.element.x) \($0.element.y) \($0.element.z)"
    }.joined(separator: "\n")
    let source = """
    $MeshFormat
    2.2 0 8
    $EndMeshFormat
    $Nodes
    8
    \(nodeLines)
    $EndNodes
    $Elements
    1
    1 5 0 1 2 3 4 5 6 7 8
    $EndElements
    """
    let imported = try GmshImporter.decode(source)
    #expect(imported.mesh.elements.first?.type == .hexahedron8)
}

@Test func convergenceEstimatorRecoversSecondOrderSequence() throws {
    let result = try MeshConvergenceStudy.evaluate(samples: [
        MeshConvergenceSample(characteristicSize: 0.5, elementCount: 4, response: 0.75),
        MeshConvergenceSample(characteristicSize: 0.25, elementCount: 16, response: 0.9375),
        MeshConvergenceSample(characteristicSize: 0.125, elementCount: 64, response: 0.984375),
    ])
    #expect(abs(try #require(result.observedOrder) - 2) < 1e-12)
    #expect(abs(try #require(result.richardsonExtrapolation) - 1) < 1e-12)
}

@Test func frameElementHasRigidBodyNullModesAndAxialStiffness() throws {
    let element = EulerBernoulliFrame2D(
        youngModulus: 200, area: 3, secondMoment: 2
    )
    let contribution = try element.stiffnessContribution(
        first: SIMD2(0, 0), second: SIMD2(2, 0), degreesOfFreedom: Array(0..<6)
    )
    #expect(abs(contribution.matrix[0] - 300) < 1e-12)
    let rigidTranslation = [1.0, 0, 0, 1, 0, 0]
    let operatorValue = try FEMElementOperator(
        dimension: 6, contributions: [contribution]
    ).multiply(rigidTranslation)
    #expect(operatorValue.allSatisfy { abs($0) < 1e-12 })
}

@Test func membraneShellKernelIsInvariantToRigidTranslation() throws {
    let element = TriangularMembraneShell3D(
        youngModulus: 100, poissonRatio: 0.25, thickness: 0.1
    )
    let contribution = try element.stiffnessContribution(
        nodes: [SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(0, 1, 1)],
        degreesOfFreedom: Array(0..<9)
    )
    let rigid = [1.0, 2, 3, 1, 2, 3, 1, 2, 3]
    let value = try FEMElementOperator(
        dimension: 9, contributions: [contribution]
    ).multiply(rigid)
    #expect(value.allSatisfy { abs($0) < 1e-11 })
}

@Test func schemaElevenPersistsP11ASettingsAndMigratesVersionTen() throws {
    var project = try MeshLabProject.cantileverExample()
    project.modalSolver = .sparseSubspace
    project.thermalStudy.surfaceConditions = [.convection(
        nodes: [0, 1, 2], coefficient: 4, ambientTemperature: 290
    )]
    let data = try MeshLabProjectFile.encode(project)
    #expect(try MeshLabProjectFile.decode(data) == project)

    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 10
    object.removeValue(forKey: "modalSolver")
    if var thermal = object["thermalStudy"] as? [String: Any] {
        thermal.removeValue(forKey: "surfaceConditions")
        object["thermalStudy"] = thermal
    }
    let migrated = try MeshLabProjectFile.decode(
        try JSONSerialization.data(withJSONObject: object)
    )
    #expect(migrated.modalSolver == .automatic)
    #expect(migrated.thermalStudy.surfaceConditions.isEmpty)
}
