import Testing
import simd
@testable import MeshLabCore

private func unitTetrahedron() throws -> Mesh {
    let nodes = [
        SIMD3<Double>(0, 0, 0),
        SIMD3<Double>(1, 0, 0),
        SIMD3<Double>(0, 1, 0),
        SIMD3<Double>(0, 0, 1),
    ]
    return try Mesh(
        nodes: nodes,
        elements: [Element(type: .tetrahedron4, nodes: [0, 1, 2, 3])]
    )
}

@Test func tetRecoversUniformStrainStress() throws {
    let mesh = try unitTetrahedron()
    let material = try ElasticMaterial(youngModulus: 210e9, poissonRatio: 0.3)
    let kinematics = try ElementKinematics.compute(
        mesh: mesh,
        material: material,
        elementIndex: 0
    )

    let strainXX = 0.01
    let localDisplacement = [
        0.0, 0.0, 0.0,
        strainXX, 0.0, 0.0,
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
    ]
    let stress = kinematics.stress(localDisplacement: localDisplacement)
    let lambda = material.lameLambda
    let mu = material.shearModulus

    let scale = abs((lambda + 2 * mu) * strainXX)
    #expect(abs(stress[0] - (lambda + 2 * mu) * strainXX) < scale * 1e-9)
    #expect(abs(stress[1] - lambda * strainXX) < scale * 1e-9)
    #expect(abs(stress[2] - lambda * strainXX) < scale * 1e-9)
    #expect(abs(stress[3]) < scale * 1e-9)
    #expect(abs(stress[4]) < scale * 1e-9)
    #expect(abs(stress[5]) < scale * 1e-9)
}

@Test func cantileverStaticSolveIsInEquilibrium() throws {
    let mesh = try MeshGenerators.structuredBox(
        size: SIMD3<Double>(1, 1, 10),
        divisions: SIMD3<Int>(1, 1, 10)
    )
    let material = try ElasticMaterial(
        youngModulus: 210e9,
        poissonRatio: 0.3,
        density: 7800
    )
    let fixedNodes = mesh.nodeIndices { abs($0.z) < 1e-12 }
    let constraints = fixedNodes.map { DirichletCondition.fixed(node: $0) }

    let surface = try mesh.makeSurfaceMesh()
    var loads: [Load] = []
    for triangle in stride(from: 0, to: surface.indices.count, by: 3) {
        let face = [
            surface.sourceNodes[Int(surface.indices[triangle])],
            surface.sourceNodes[Int(surface.indices[triangle + 1])],
            surface.sourceNodes[Int(surface.indices[triangle + 2])],
        ]
        if face.allSatisfy({ abs(mesh.nodes[$0].z - 10) < 1e-12 }) {
            loads.append(.traction(
                nodes: face,
                vector: SIMD3<Double>(0, 0, -1000)
            ))
        }
    }
    #expect(loads.count == 2)

    let model = FEMModel(
        mesh: mesh,
        material: material,
        constraints: constraints,
        loads: loads
    )

    let accelerate = try StaticAnalysis(
        options: AnalysisOptions(solverMethod: .accelerateCholesky)
    ).solve(model)

    #expect(accelerate.solveReport.converged)
    #expect(accelerate.maxDisplacement > 0)
    #expect(accelerate.maxVonMises > 0)
    #expect(accelerate.strainEnergy > 0)

    let reactionSum = accelerate.reactions.reduce(SIMD3<Double>.zero, +)
    #expect(abs(reactionSum.x) < 1e-5)
    #expect(abs(reactionSum.y) < 1e-5)
    #expect(abs(reactionSum.z - 1000) < 1e-3)

    let numericCore = try StaticAnalysis(
        options: AnalysisOptions(solverMethod: .numericCoreCholesky)
    ).solve(model)
    #expect(abs(numericCore.maxDisplacement - accelerate.maxDisplacement)
        / accelerate.maxDisplacement < 1e-6)

    let numericCoreLU = try StaticAnalysis(
        options: AnalysisOptions(solverMethod: .numericCoreLU)
    ).solve(model)
    #expect(abs(numericCoreLU.maxDisplacement - accelerate.maxDisplacement)
        / accelerate.maxDisplacement < 1e-6)

    let numericCoreLDLT = try StaticAnalysis(
        options: AnalysisOptions(solverMethod: .numericCoreLDLT)
    ).solve(model)
    #expect(abs(numericCoreLDLT.maxDisplacement - accelerate.maxDisplacement)
        / accelerate.maxDisplacement < 1e-6)
    #expect(numericCoreLDLT.solveReport.inertia?.positive == mesh.dofCount - constraints.count * 3)

    let iterative = try StaticAnalysis(
        options: AnalysisOptions(
            solverMethod: .conjugateGradient(.init(
                maxIterations: 5_000,
                tolerance: 1e-10,
                preconditioner: .jacobi
            ))
        )
    ).solve(model)
    #expect(iterative.solveReport.converged)
    #expect(abs(iterative.maxDisplacement - accelerate.maxDisplacement)
        / accelerate.maxDisplacement < 1e-6)
}

@Test func planeStressModelSolves() throws {
    let mesh = try MeshGenerators.structuredRectangle(
        width: 2,
        height: 1,
        divisions: SIMD2<Int>(2, 1)
    )
    let material = try ElasticMaterial(
        youngModulus: 200e9,
        poissonRatio: 0.3,
        planeKinematics: .planeStress,
        thickness: 0.1
    )
    let constraints = mesh.nodeIndices { abs($0.x) < 1e-12 }
        .map { DirichletCondition.fixed(node: $0) }
    let loadedNodes = mesh.nodeIndices { abs($0.x - 2) < 1e-12 }
    let loads = loadedNodes.map {
        Load.nodal(node: $0, vector: SIMD3<Double>(0, -50, 0))
    }

    let model = FEMModel(
        mesh: mesh,
        material: material,
        constraints: constraints,
        loads: loads
    )
    let result = try StaticAnalysis().solve(model)

    #expect(result.solveReport.converged)
    #expect(result.maxDisplacement > 0)
    #expect(result.maxVonMises > 0)
    #expect(result.elementStresses.allSatisfy { $0.components[4] == 0 && $0.components[5] == 0 })

    let reactionSum = result.reactions.reduce(SIMD3<Double>.zero, +)
    #expect(abs(reactionSum.y - 100) < 1e-6)
}

@Test func conflictingConstraintsAreRejected() throws {
    let mesh = try unitTetrahedron()
    let material = try ElasticMaterial(youngModulus: 1e9, poissonRatio: 0.25)
    let model = FEMModel(
        mesh: mesh,
        material: material,
        constraints: [
            DirichletCondition(node: 0, axis: 0, value: 0),
            DirichletCondition(node: 0, axis: 0, value: 1),
        ]
    )
    #expect(throws: FEMError.self) {
        _ = try StaticAnalysis().solve(model)
    }
}

@Test func disconnectedFreeRegionIsRejected() throws {
    let nodes = [
        SIMD3<Double>(0, 0, 0),
        SIMD3<Double>(1, 0, 0),
        SIMD3<Double>(0, 1, 0),
        SIMD3<Double>(0, 0, 1),
        SIMD3<Double>(2, 0, 0),
        SIMD3<Double>(3, 0, 0),
        SIMD3<Double>(2, 1, 0),
        SIMD3<Double>(2, 0, 1),
    ]
    let mesh = try Mesh(nodes: nodes, elements: [
        Element(type: .tetrahedron4, nodes: [0, 1, 2, 3]),
        Element(type: .tetrahedron4, nodes: [4, 5, 6, 7]),
    ])
    let material = try ElasticMaterial(youngModulus: 1e9, poissonRatio: 0.25)
    let model = FEMModel(
        mesh: mesh,
        material: material,
        constraints: [DirichletCondition.fixed(node: 0)]
    )
    #expect(throws: FEMError.self) {
        _ = try StaticAnalysis().solve(model)
    }
}

@Test func threeDimensionalPatchTestReproducesLinearField() throws {
    let mesh = try MeshGenerators.structuredBox(
        size: SIMD3<Double>(1, 1, 1),
        divisions: SIMD3<Int>(2, 2, 2)
    )
    let material = try ElasticMaterial(youngModulus: 210e9, poissonRatio: 0.3)
    let strain = SIMD3<Double>(0.01, -0.003, 0.002)

    let boundary = mesh.nodeIndices { point in
        point.x == 0 || point.x == 1
            || point.y == 0 || point.y == 1
            || point.z == 0 || point.z == 1
    }
    let constraints = boundary.flatMap { node in
        (0..<3).map { axis in
            DirichletCondition(
                node: node,
                axis: axis,
                value: strain[axis] * mesh.nodes[node][axis]
            )
        }
    }
    let model = FEMModel(
        mesh: mesh,
        material: material,
        constraints: constraints
    )
    let result = try StaticAnalysis(
        options: AnalysisOptions(solverMethod: .numericCoreLDLT)
    ).solve(model)

    let interior = mesh.nodeIndices { point in
        abs(point.x - 0.5) < 1e-12
            && abs(point.y - 0.5) < 1e-12
            && abs(point.z - 0.5) < 1e-12
    }
    #expect(interior.count == 1)
    let node = try #require(interior.first)
    for axis in 0..<3 {
        #expect(abs(result.displacements[node][axis] - strain[axis] * 0.5) < 1e-12)
    }

    let lambda = material.lameLambda
    let mu = material.shearModulus
    let expected = [
        (lambda + 2 * mu) * strain.x + lambda * (strain.y + strain.z),
        lambda * strain.x + (lambda + 2 * mu) * strain.y + lambda * strain.z,
        lambda * (strain.x + strain.y) + (lambda + 2 * mu) * strain.z,
        0.0,
        0.0,
        0.0,
    ]
    let scale = expected.map(abs).max() ?? 1
    for stress in result.elementStresses {
        for index in 0..<6 {
            #expect(abs(stress.components[index] - expected[index]) < scale * 1e-9)
        }
    }
}
