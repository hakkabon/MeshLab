import Foundation
import Testing
import simd
@testable import MeshLabCore

private func planarCantilever(
    width: Double = 4,
    height: Double = 1,
    divisions: SIMD2<Int> = SIMD2(8, 2)
) throws -> FEMModel {
    let mesh = try MeshGenerators.structuredRectangle(
        width: width,
        height: height,
        divisions: divisions
    )
    let material = try ElasticMaterial(
        youngModulus: 100e9,
        poissonRatio: 0.3,
        density: 7800,
        thickness: 1
    )
    let constraints = mesh.nodeIndices { abs($0.x) < 1e-12 }
        .map { DirichletCondition.fixed(node: $0) }
    let right = try #require(mesh.nodeIndices { abs($0.x - width) < 1e-12 }.first)
    return FEMModel(
        mesh: mesh,
        material: material,
        constraints: constraints,
        loads: [Load.nodal(node: right, vector: SIMD3<Double>(0, -1_000, 0))]
    )
}

@Test func parametricSweepShowsStiffnessAndLoadScaling() throws {
    let project = try MeshLabProject.cantileverExample()
    let study = ParametricStudy(axes: [
        ParametricAxis(parameter: .youngModulus, values: [100e9, 200e9]),
        ParametricAxis(parameter: .loadScale, values: [0.5, 1]),
    ])
    let result = try study.solve(project)

    #expect(result.samples.count == 4)
    #expect(result.bestIndex == 2)
    let best = try #require(result.best)
    #expect(result.value(of: .youngModulus, in: best) == 200e9)
    #expect(result.value(of: .loadScale, in: best) == 0.5)
    #expect(result.samples.allSatisfy { $0.compliance > 0 })
    #expect(abs(result.bestResult.maxDisplacement - best.maxDisplacement) < 1e-12)
    #expect(result.bestResult.displacements.count == result.bestModel.mesh.nodes.count)
}

@Test func complianceAdjointMatchesFiniteDifference() throws {
    let model = try planarCantilever()
    let sensitivity = try ComplianceAdjoint.solve(model)

    let index = 5
    let step = 1e-5
    var plus = model
    plus.elementStiffnessScales = [Double](
        repeating: 1,
        count: model.mesh.elements.count
    )
    plus.elementStiffnessScales[index] += step
    var minus = plus
    minus.elementStiffnessScales[index] -= 2 * step
    let plusCompliance = 2 * (try StaticAnalysis().solve(plus)).strainEnergy
    let minusCompliance = 2 * (try StaticAnalysis().solve(minus)).strainEnergy
    let finiteDifference = (plusCompliance - minusCompliance) / (2 * step)
    let analytic = sensitivity.elementStiffnessGradient[index]
    #expect(abs(analytic - finiteDifference) / max(abs(finiteDifference), 1) < 1e-5)

    var stiffer = model
    stiffer.material = try ElasticMaterial(
        youngModulus: model.material.youngModulus * (1 + step),
        poissonRatio: model.material.poissonRatio,
        density: model.material.density,
        thickness: model.material.thickness
    )
    var softer = model
    softer.material = try ElasticMaterial(
        youngModulus: model.material.youngModulus * (1 - step),
        poissonRatio: model.material.poissonRatio,
        density: model.material.density,
        thickness: model.material.thickness
    )
    let stiffCompliance = 2 * (try StaticAnalysis().solve(stiffer)).strainEnergy
    let softCompliance = 2 * (try StaticAnalysis().solve(softer)).strainEnergy
    let modulusDerivative = (stiffCompliance - softCompliance)
        / (2 * step * model.material.youngModulus)
    #expect(abs(sensitivity.youngModulusGradient - modulusDerivative)
        / max(abs(modulusDerivative), 1) < 1e-5)
}

@Test func topologyOptimizationMeetsVolumeAndReducesCompliance() throws {
    let model = try planarCantilever()
    let result = try TopologyOptimization(options: TopologyOptions(
        volumeFraction: 0.5,
        penalty: 3,
        filterRadius: 0,
        outerIterations: 4,
        innerIterations: 20,
        volumeTolerance: 0.03
    )).solve(model)

    #expect(result.densities.count == model.mesh.elements.count)
    #expect(result.stiffnessScales.count == model.mesh.elements.count)
    #expect(result.densities.allSatisfy { $0 >= 1e-3 && $0 <= 1 })
    #expect(abs(result.volumeFraction - 0.5) < 0.05)
    #expect(result.finalCompliance <= result.initialCompliance * 1.01)
    #expect(result.iterations.count >= 1)
}

@Test func shapeAdjointMatchesFiniteDifference() throws {
    let model = try planarCantilever()
    let node = try #require(model.mesh.nodeIndices {
        abs($0.x - 4) < 1e-12 && abs($0.y - 0.5) < 1e-12
    }.first)
    let variable = ShapeDesignVariable(
        node: node,
        axis: 1,
        lower: 0.3,
        upper: 0.7
    )
    let optimization = ShapeOptimization()
    let sensitivity = try optimization.sensitivity(model, variables: [variable])

    let step = 1e-5
    var plus = model.mesh
    plus.nodes[node][1] += step
    var minus = model.mesh
    minus.nodes[node][1] -= step
    let plusMesh = try Mesh(nodes: plus.nodes, elements: plus.elements)
    let minusMesh = try Mesh(nodes: minus.nodes, elements: minus.elements)
    var plusModel = model
    plusModel.mesh = plusMesh
    var minusModel = model
    minusModel.mesh = minusMesh
    let plusCompliance = 2 * (try StaticAnalysis().solve(plusModel)).strainEnergy
    let minusCompliance = 2 * (try StaticAnalysis().solve(minusModel)).strainEnergy
    let finiteDifference = (plusCompliance - minusCompliance) / (2 * step)
    let analytic = sensitivity.complianceGradient[0]
    #expect(abs(analytic - finiteDifference) / max(abs(finiteDifference), 1) < 1e-4)
    #expect(sensitivity.volumeGradient[0].isFinite)
}

@Test func shapeSensitivityUsesOneSidedDifferenceAtBounds() throws {
    let model = try planarCantilever()
    let node = try #require(model.mesh.nodeIndices {
        abs($0.x - 4) < 1e-12 && abs($0.y - 0.5) < 1e-12
    }.first)
    let sensitivity = try ShapeOptimization().sensitivity(
        model,
        variables: [ShapeDesignVariable(
            node: node,
            axis: 1,
            lower: model.mesh.nodes[node].y,
            upper: model.mesh.nodes[node].y + 0.2
        )]
    )
    #expect(sensitivity.complianceGradient[0].isFinite)
    #expect(sensitivity.volumeGradient[0].isFinite)
}

@Test func shapeOptimizationPreservesAValidVolume() throws {
    let model = try planarCantilever()
    var variables: [ShapeDesignVariable] = []
    for x in [2.0, 4.0] {
        for y in [0.0, 1.0] {
            guard let node = model.mesh.nodeIndices(where: {
                abs($0.x - x) < 1e-12 && abs($0.y - y) < 1e-12
            }).first else { continue }
            variables.append(ShapeDesignVariable(
                node: node,
                axis: 1,
                lower: y - 0.15,
                upper: y + 0.15
            ))
        }
    }
    let result = try ShapeOptimization(options: ShapeOptions(
        volumeTargetRatio: 1,
        outerIterations: 2,
        innerIterations: 5,
        volumeTolerance: 0.05
    )).solve(model, variables: variables)

    #expect(result.mesh.nodes.count == model.mesh.nodes.count)
    #expect(result.mesh.elements.count == model.mesh.elements.count)
    #expect(result.staticResult.maxDisplacement > 0)
    #expect(abs(result.volumeFraction - 1) < 0.2)
    #expect(result.finalCompliance <= result.initialCompliance * 1.05)
    #expect(result.iterations.count >= 1)
}

@Test func designStudiesRunOnTheExampleCantilever() throws {
    var project = try MeshLabProject.cantileverExample()
    project.designStudy.topology = TopologyStudy(
        volumeFraction: 0.6,
        filterRadius: 0.2,
        outerIterations: 1,
        innerIterations: 5,
        volumeTolerance: 0.05
    )
    project.designStudy.kind = .topology
    guard case .topology(let topology) = try project.designStudy.run(on: project) else {
        Issue.record("Expected a topology result")
        return
    }
    #expect(topology.finalModel.mesh == project.mesh)
    #expect(topology.stiffnessScales.count == project.mesh.elements.count)
    #expect(topology.finalResult.maxDisplacement.isFinite)

    project.designStudy.kind = .shape
    project.designStudy.shape = ShapeStudy(
        selectionAxis: 2,
        motionAxis: 0,
        margin: 0.05,
        outerIterations: 1,
        innerIterations: 1,
        volumeTolerance: 0.1
    )
    guard case .shape(let shape) = try project.designStudy.run(on: project) else {
        Issue.record("Expected a shape result")
        return
    }
    #expect(shape.mesh.nodes.count == project.mesh.nodes.count)
    #expect(shape.staticResult.maxDisplacement.isFinite)
}

@Test func designStudiesRejectInvalidStudyDefinitions() throws {
    let project = try MeshLabProject.cantileverExample()
    #expect(throws: DesignError.self) {
        try ParametricStudy(axes: []).solve(project)
    }
    #expect(throws: DesignError.self) {
        try ParametricStudy(axes: [
            ParametricAxis(parameter: .youngModulus, values: [-1]),
        ]).solve(project)
    }

    let model = try planarCantilever()
    #expect(throws: DesignError.self) {
        try TopologyOptimization(options: TopologyOptions(volumeFraction: 0))
            .solve(model)
    }
    #expect(throws: DesignError.self) {
        try ShapeOptimization().solve(model, variables: [])
    }

    var prescribed = model
    prescribed.constraints = [
        DirichletCondition(node: 0, axis: 0, value: 0.01),
    ]
    #expect(throws: DesignError.self) {
        try ComplianceAdjoint.solve(prescribed)
    }
}
