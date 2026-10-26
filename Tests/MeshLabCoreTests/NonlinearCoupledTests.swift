import Foundation
import MeshLabCore
import Testing
import simd

private func nonlinearTetra(load: Double, modulus: Double = 1e7) throws -> FEMModel {
    let mesh = try Mesh(
        nodes: [
            SIMD3<Double>(0, 0, 0),
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, 1, 0),
            SIMD3<Double>(0, 0, 1),
        ],
        elements: [Element(type: .tetrahedron4, nodes: [0, 1, 2, 3])]
    )
    let material = try ElasticMaterial(youngModulus: modulus, poissonRatio: 0.3)
    return FEMModel(
        mesh: mesh,
        material: material,
        constraints: [
            .fixed(node: 0),
            .fixed(node: 1, axis: 1),
            .fixed(node: 1, axis: 2),
            .fixed(node: 2, axis: 2),
        ],
        loads: [.nodal(node: 3, vector: SIMD3<Double>(0, 0, load))]
    )
}

@Test func finiteStrainSmallLoadMatchesLinearReference() throws {
    let model = try nonlinearTetra(load: 10)
    let linear = try StaticAnalysis(options: AnalysisOptions(
        solverMethod: .numericCoreCholesky
    )).solve(model)
    let nonlinear = try NonlinearStaticAnalysis(options: NonlinearStaticOptions(
        loadSteps: 2,
        maximumNewtonIterations: 20,
        residualTolerance: 1e-10,
        stepTolerance: 1e-12
    )).solve(model)

    #expect(nonlinear.loadSteps.count == 2)
    #expect(nonlinear.staticResult.solveReport.converged)
    #expect(abs(nonlinear.staticResult.maxDisplacement - linear.maxDisplacement)
        / linear.maxDisplacement < 1e-4)
    #expect(nonlinear.staticResult.equilibrium.relativeFreeResidual < 1e-9)
}

@Test func finiteStrainResponseDepartsFromLinearAtLargeDeformation() throws {
    let model = try nonlinearTetra(load: 500_000, modulus: 1e7)
    let linear = try StaticAnalysis().solve(model)
    let nonlinear = try NonlinearStaticAnalysis(options: NonlinearStaticOptions(
        loadSteps: 12,
        maximumNewtonIterations: 30,
        residualTolerance: 1e-9
    )).solve(model)

    #expect(nonlinear.staticResult.maxDisplacement.isFinite)
    #expect(abs(nonlinear.staticResult.maxDisplacement - linear.maxDisplacement)
        / linear.maxDisplacement > 0.01)
    #expect(nonlinear.totalNewtonIterations > 0)
}

@Test func finiteStrainRejectsNonzeroPrescribedDisplacement() throws {
    var model = try nonlinearTetra(load: 10)
    model.constraints.removeFirst()
    model.constraints.append(contentsOf: [
        DirichletCondition(node: 0, axis: 0, value: 0.01),
        .fixed(node: 0, axis: 1),
        .fixed(node: 0, axis: 2),
    ])
    #expect(throws: NonlinearStaticError.self) {
        _ = try NonlinearStaticAnalysis().solve(model)
    }
}

@Test func staggeredThermoMechanicalCouplingConvergesAndSoftensMaterial() throws {
    let mesh = try MeshGenerators.structuredBox(
        size: SIMD3<Double>(1, 1, 2),
        divisions: SIMD3<Int>(1, 1, 2)
    )
    let material = try ElasticMaterial(
        youngModulus: 1e7,
        poissonRatio: 0.3,
        thermalConductivity: 10,
        thermalExpansion: 0
    )
    let bottom = mesh.nodeIndices { abs($0.z) < 1e-12 }
    let top = mesh.nodeIndices { abs($0.z - 2) < 1e-12 }
    let thermal = ThermalModel(
        mesh: mesh,
        material: material,
        constraints: bottom.map { ThermalConstraint(node: $0, temperature: 20) }
            + top.map { ThermalConstraint(node: $0, temperature: 120) }
    )
    let structural = FEMModel(
        mesh: mesh,
        material: material,
        constraints: bottom.map { .fixed(node: $0) },
        loads: top.map { .nodal(node: $0, vector: SIMD3<Double>(0, 0, -250)) }
    )
    let uncoupled = try StaticAnalysis().solve(structural)
    let coupled = try CoupledThermoMechanicalAnalysis(
        options: CoupledThermoMechanicalOptions(
            maximumIterations: 12,
            relativeTolerance: 1e-8,
            relaxation: 1,
            youngModulusTemperatureCoefficient: -0.005,
            minimumYoungModulusFactor: 0.2
        ),
        referenceTemperature: 20
    ).solve(thermal: thermal, structural: structural)

    #expect(coupled.converged)
    #expect(coupled.iterations.count >= 2)
    #expect(coupled.thermalResult.maximumTemperature == 120)
    #expect(coupled.staticResult.maxDisplacement > uncoupled.maxDisplacement)
}

@Test func projectVersionSevenRoundTripsAndMigratesVersionSix() throws {
    var project = try MeshLabProject.cantileverExample()
    project.analysis = .nonlinearStatic
    project.nonlinearOptions.loadSteps = 7
    project.coupledOptions.relaxation = 0.4
    let data = try MeshLabProjectFile.encode(project)
    let decoded = try MeshLabProjectFile.decode(data)
    #expect(decoded == project)
    #expect(decoded.schemaVersion == 7)

    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 6
    object.removeValue(forKey: "nonlinearOptions")
    object.removeValue(forKey: "coupledOptions")
    let migrated = try MeshLabProjectFile.decode(
        try JSONSerialization.data(withJSONObject: object)
    )
    #expect(migrated.schemaVersion == 6)
    #expect(migrated.nonlinearOptions == NonlinearStaticOptions())
    #expect(migrated.coupledOptions == CoupledThermoMechanicalOptions())
}
