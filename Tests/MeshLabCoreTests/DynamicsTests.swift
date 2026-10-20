import Foundation
import Testing
import simd
@testable import MeshLabCore

private func axialRod() throws -> (FEMModel, ElasticMaterial) {
    let mesh = try MeshGenerators.structuredBox(
        size: SIMD3<Double>(1, 1, 4),
        divisions: SIMD3<Int>(1, 1, 8)
    )
    let material = try ElasticMaterial(
        youngModulus: 200e9,
        poissonRatio: 0.3,
        density: 7800
    )
    var constraints: [DirichletCondition] = []
    for node in mesh.nodes.indices {
        constraints.append(DirichletCondition(node: node, axis: 0))
        constraints.append(DirichletCondition(node: node, axis: 1))
        if abs(mesh.nodes[node].z) < 1e-12 {
            constraints.append(DirichletCondition(node: node, axis: 2))
        }
    }
    return (
        FEMModel(mesh: mesh, material: material, constraints: constraints),
        material
    )
}

@Test func modalAnalysisFindsFixedFreeAxialFrequency() throws {
    let (model, material) = try axialRod()
    let result = try ModalAnalysis(options: ModalOptions(modeCount: 2)).solve(model)

    let constrainedModulus = material.lameLambda + 2 * material.shearModulus
    let expected = sqrt(constrainedModulus / material.density) / (4 * 4)
    #expect(result.modes.count == 2)
    #expect(abs(result.modes[0].frequencyHz - expected) / expected < 0.02)
    #expect(result.modes[1].frequencyHz > result.modes[0].frequencyHz)
    #expect(result.maximumRelativeResidual < 1e-8)
    #expect(result.maximumMassOrthogonalityError < 1e-8)
    #expect(result.modeShapes.allSatisfy { $0.count == model.mesh.dofCount })
}

@Test func modalAnalysisRejectsNonzeroConstraints() throws {
    let (model, _) = try axialRod()
    var loaded = model
    loaded.constraints.append(DirichletCondition(node: 0, axis: 2, value: 0.001))
    #expect(throws: FEMError.self) {
        _ = try ModalAnalysis(options: ModalOptions(modeCount: 1)).solve(loaded)
    }
}

@Test func transientUndampedFirstModeCompletesAPeriod() throws {
    let (model, _) = try axialRod()
    let modal = try ModalAnalysis(options: ModalOptions(modeCount: 1)).solve(model)
    let mode = try #require(modal.modes.first)
    let amplitude = 1e-4
    let initial = mode.displacements.map { $0 * amplitude }
    let period = 1 / mode.frequencyHz
    let steps = 400
    let options = TransientOptions(
        timeStep: period / Double(steps),
        steps: steps
    )
    let result = try TransientAnalysis(options: options).solve(
        model,
        loadHistory: Array(repeating: [], count: steps + 1),
        initialDisplacement: initial
    )

    let first = try #require(result.states.first)
    let last = try #require(result.states.last)
    #expect(last.time == period)
    #expect(result.states.count == steps + 1)
    #expect(result.maximumRelativeEquilibriumResidual < 1e-6)
    for node in model.mesh.nodes.indices {
        #expect(abs(last.displacement[node].z - first.displacement[node].z)
            <= amplitude * 5e-3)
    }
    #expect(first.acceleration.contains { abs($0.z) > 0 })
}

@Test func transientMassDampingDissipatesEnergy() throws {
    let (model, _) = try axialRod()
    let modal = try ModalAnalysis(options: ModalOptions(modeCount: 1)).solve(model)
    let mode = try #require(modal.modes.first)
    let initial = mode.displacements.map { $0 * 1e-4 }
    let period = 1 / mode.frequencyHz
    let steps = 200
    let result = try TransientAnalysis(options: TransientOptions(
        timeStep: period / Double(steps),
        steps: steps,
        massDamping: 20,
        stiffnessDamping: 0
    )).solve(
        model,
        loadHistory: Array(repeating: [], count: steps + 1),
        initialDisplacement: initial
    )

    let initialEnergy = try #require(result.states.first).strainEnergy
    let finalEnergy = try #require(result.states.last).strainEnergy
    #expect(finalEnergy < initialEnergy)
    #expect(result.maximumRelativeEquilibriumResidual < 1e-6)
}

@Test func transientStiffnessDampingDissipatesEnergy() throws {
    let (model, _) = try axialRod()
    let modal = try ModalAnalysis(options: ModalOptions(modeCount: 1)).solve(model)
    let mode = try #require(modal.modes.first)
    let initial = mode.displacements.map { $0 * 1e-4 }
    let period = 1 / mode.frequencyHz
    let steps = 200
    let result = try TransientAnalysis(options: TransientOptions(
        timeStep: period / Double(steps),
        steps: steps,
        massDamping: 0,
        stiffnessDamping: 1e-5
    )).solve(
        model,
        loadHistory: Array(repeating: [], count: steps + 1),
        initialDisplacement: initial
    )

    let initialEnergy = try #require(result.states.first).strainEnergy
    let finalEnergy = try #require(result.states.last).strainEnergy
    #expect(finalEnergy < initialEnergy)
    #expect(result.maximumRelativeEquilibriumResidual < 1e-6)
}
