import Testing
import simd
@testable import MeshLabCore

@Test func structuredBoxHasExpectedTopologyAndVolume() throws {
    let mesh = try MeshGenerators.structuredBox(
        size: SIMD3<Double>(2, 2, 2),
        divisions: SIMD3<Int>(1, 1, 1)
    )
    #expect(mesh.nodes.count == 8)
    #expect(mesh.elements.count == 6)
    #expect(abs(mesh.measure - 8) < 1e-12)

    let surface = try mesh.makeSurfaceMesh()
    #expect(surface.triangleCount == 12)
    #expect(surface.sourceNodes.count == 8)
    #expect(surface.indices.count == 36)
    #expect(surface.normals.allSatisfy { abs(simd_length($0) - 1) < 1e-5 })
}

@Test func refinedBoxPreservesVolumeAndBoundary() throws {
    let mesh = try MeshGenerators.structuredBox(
        size: SIMD3<Double>(2, 2, 2),
        divisions: SIMD3<Int>(2, 2, 2)
    )
    #expect(mesh.elements.count == 48)
    #expect(abs(mesh.measure - 8) < 1e-12)

    let surface = try mesh.makeSurfaceMesh()
    #expect(surface.triangleCount == 48)
}

@Test func surfaceNormalsPointOutwardForConvexBox() throws {
    let mesh = try MeshGenerators.structuredBox(
        size: SIMD3<Double>(2, 2, 2),
        divisions: SIMD3<Int>(2, 2, 2)
    )
    let center = mesh.center
    let surface = try mesh.makeSurfaceMesh()

    for triangle in stride(from: 0, to: surface.indices.count, by: 3) {
        let i0 = Int(surface.indices[triangle])
        let i1 = Int(surface.indices[triangle + 1])
        let i2 = Int(surface.indices[triangle + 2])
        let p0 = doubleVector(surface.positions[i0])
        let p1 = doubleVector(surface.positions[i1])
        let p2 = doubleVector(surface.positions[i2])
        let normal = simd_cross(p1 - p0, p2 - p0)
        let faceCenter = (p0 + p1 + p2) / 3
        #expect(simd_dot(normal, faceCenter - center) > 0)
        #expect(simd_dot(doubleVector(surface.normals[i0]), normal) > 0)
    }
}

@Test func structuredRectangleProducesPlanarSurface() throws {
    let mesh = try MeshGenerators.structuredRectangle(
        width: 2,
        height: 1,
        divisions: SIMD2<Int>(2, 1)
    )
    #expect(mesh.nodes.count == 6)
    #expect(mesh.elements.count == 4)
    #expect(abs(mesh.measure - 2) < 1e-12)

    let surface = try mesh.makeSurfaceMesh()
    #expect(surface.triangleCount == 4)
    #expect(surface.normals.allSatisfy { $0.z > 0.99 })
}

@Test func invalidConnectivityIsRejected() {
    let nodes = [
        SIMD3<Double>(0, 0, 0),
        SIMD3<Double>(1, 0, 0),
        SIMD3<Double>(0, 1, 0),
    ]
    #expect(throws: MeshError.self) {
        _ = try Mesh(nodes: nodes, elements: [Element(type: .tetrahedron4, nodes: [0, 1, 2])])
    }
    #expect(throws: MeshError.self) {
        _ = try Mesh(nodes: nodes, elements: [Element(type: .triangle3, nodes: [0, 2, 7])])
    }
}

private func doubleVector(_ value: SIMD3<Float>) -> SIMD3<Double> {
    SIMD3<Double>(Double(value.x), Double(value.y), Double(value.z))
}
