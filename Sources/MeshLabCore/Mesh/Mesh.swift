import Foundation
import simd

public enum ElementType: String, Sendable, Hashable, Codable {
    case tetrahedron4
    case triangle3

    public var nodeCount: Int {
        switch self {
        case .tetrahedron4: return 4
        case .triangle3: return 3
        }
    }

    public var dimension: Int {
        switch self {
        case .tetrahedron4: return 3
        case .triangle3: return 2
        }
    }

    public var faces: [[Int]] {
        switch self {
        case .tetrahedron4:
            return [
                [0, 1, 2],
                [0, 1, 3],
                [0, 2, 3],
                [1, 2, 3],
            ]
        case .triangle3:
            return [[0, 1, 2]]
        }
    }
}

public struct Element: Sendable, Hashable, Codable {
    public let type: ElementType
    public let nodes: [Int]

    public init(type: ElementType, nodes: [Int]) {
        self.type = type
        self.nodes = nodes
    }
}

public enum MeshError: Error, Equatable, Sendable {
    case emptyMesh
    case nonFiniteCoordinate(node: Int)
    case wrongNodeCount(element: Int)
    case nodeIndexOutOfRange(element: Int, node: Int)
    case repeatedNode(element: Int)
    case mixedDimensions
    case degenerateElement(Int)
    case emptySurface
    case invalidSurfaceVertexCount
    case invalidSurfaceIndex(UInt32)
    case invalidSurfaceNode(Int)
}

public struct Mesh: Sendable, Codable, Equatable {
    public var nodes: [SIMD3<Double>]
    public var elements: [Element]

    public init(nodes: [SIMD3<Double>], elements: [Element]) throws {
        guard !nodes.isEmpty, !elements.isEmpty else {
            throw MeshError.emptyMesh
        }
        for (index, node) in nodes.enumerated() {
            guard node.x.isFinite, node.y.isFinite, node.z.isFinite else {
                throw MeshError.nonFiniteCoordinate(node: index)
            }
        }

        let dimension = elements[0].type.dimension
        for (elementIndex, element) in elements.enumerated() {
            guard element.nodes.count == element.type.nodeCount else {
                throw MeshError.wrongNodeCount(element: elementIndex)
            }
            guard element.type.dimension == dimension else {
                throw MeshError.mixedDimensions
            }
            guard Set(element.nodes).count == element.nodes.count else {
                throw MeshError.repeatedNode(element: elementIndex)
            }
            for node in element.nodes {
                guard (0..<nodes.count).contains(node) else {
                    throw MeshError.nodeIndexOutOfRange(element: elementIndex, node: node)
                }
            }
            let coordinates = element.nodes.map { nodes[$0] }
            guard try Self.elementMeasure(type: element.type, coordinates: coordinates) > 0,
                  Self.elementQuality(type: element.type, coordinates: coordinates) > 1e-12 else {
                throw MeshError.degenerateElement(elementIndex)
            }
        }

        self.nodes = nodes
        self.elements = elements
    }

    public var dimension: Int {
        elements.first?.type.dimension ?? 0
    }

    public var dofsPerNode: Int {
        dimension
    }

    public var dofCount: Int {
        nodes.count * dofsPerNode
    }

    public var elementCount: Int {
        elements.count
    }

    public func elementCoordinates(_ index: Int) -> [SIMD3<Double>] {
        elements[index].nodes.map { nodes[$0] }
    }

    public func nodeIndices(where predicate: (SIMD3<Double>) -> Bool) -> [Int] {
        nodes.indices.filter { predicate(nodes[$0]) }
    }

    public var bounds: (minimum: SIMD3<Double>, maximum: SIMD3<Double>) {
        var minimum = nodes[0]
        var maximum = nodes[0]
        for node in nodes.dropFirst() {
            minimum = simd_min(minimum, node)
            maximum = simd_max(maximum, node)
        }
        return (minimum, maximum)
    }

    public var center: SIMD3<Double> {
        let bounds = self.bounds
        return (bounds.minimum + bounds.maximum) * 0.5
    }

    public var radius: Double {
        let center = self.center
        return nodes.reduce(0) { max($0, simd_length($1 - center)) }
    }

    public var measure: Double {
        elements.indices.reduce(0) { partial, index in
            partial + (try! Self.elementMeasure(
                type: elements[index].type,
                coordinates: elementCoordinates(index)
            ))
        }
    }

    /// Extracts the renderable boundary of the mesh.
    ///
    /// Volumetric meshes are reduced to the triangular faces used by exactly
    /// one element. Two-dimensional meshes expose their triangles directly.
    /// The returned index buffer references unique surface vertices, and
    /// `sourceNodes` maps each surface vertex back to the original node.
    public func makeSurfaceMesh() throws -> SurfaceMesh {
        switch dimension {
        case 3:
            return try makeTetrahedralSurface()
        case 2:
            return try makePlanarSurface()
        default:
            throw MeshError.emptySurface
        }
    }

    private func makeTetrahedralSurface() throws -> SurfaceMesh {
        struct FaceRecord {
            var count: Int
            var oriented: [Int]
        }

        var records: [[Int]: FaceRecord] = [:]
        records.reserveCapacity(elements.count * 2)

        for element in elements {
            let nodeIndices = element.nodes
            let coordinates = nodeIndices.map { nodes[$0] }
            let elementCenter = coordinates.reduce(SIMD3<Double>.zero, +) / 4

            for face in ElementType.tetrahedron4.faces {
                var first = nodeIndices[face[0]]
                var second = nodeIndices[face[1]]
                let third = nodeIndices[face[2]]

                let p0 = nodes[first]
                let p1 = nodes[second]
                let p2 = nodes[third]
                let faceCenter = (p0 + p1 + p2) / 3
                let normal = simd_cross(p1 - p0, p2 - p0)
                if simd_dot(normal, faceCenter - elementCenter) < 0 {
                    swap(&first, &second)
                }

                let key = [first, second, third].sorted()
                if var record = records[key] {
                    record.count += 1
                    records[key] = record
                } else {
                    records[key] = FaceRecord(count: 1, oriented: [first, second, third])
                }
            }
        }

        let boundary = records.values
            .filter { $0.count == 1 }
            .map(\.oriented)

        return try SurfaceMesh(
            faces: boundary,
            nodes: nodes,
            normalsFromFaces: true
        )
    }

    private func makePlanarSurface() throws -> SurfaceMesh {
        var faces: [[Int]] = []
        faces.reserveCapacity(elements.count)

        for element in elements {
            var first = element.nodes[0]
            var second = element.nodes[1]
            let third = element.nodes[2]
            let a = nodes[first]
            let b = nodes[second]
            let c = nodes[third]
            let signedArea = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
            if signedArea < 0 {
                swap(&first, &second)
            }
            faces.append([first, second, third])
        }

        return try SurfaceMesh(
            faces: faces,
            nodes: nodes,
            normalsFromFaces: false
        )
    }

    private static func elementMeasure(
        type: ElementType,
        coordinates: [SIMD3<Double>]
    ) throws -> Double {
        switch type {
        case .tetrahedron4:
            let a = coordinates[1] - coordinates[0]
            let b = coordinates[2] - coordinates[0]
            let c = coordinates[3] - coordinates[0]
            return abs(simd_dot(a, simd_cross(b, c))) / 6
        case .triangle3:
            let a = coordinates[1] - coordinates[0]
            let b = coordinates[2] - coordinates[0]
            return 0.5 * abs(a.x * b.y - a.y * b.x)
        }
    }

    private static func elementQuality(
        type: ElementType,
        coordinates: [SIMD3<Double>]
    ) -> Double {
        switch type {
        case .tetrahedron4:
            let edges = [
                coordinates[1] - coordinates[0],
                coordinates[2] - coordinates[0],
                coordinates[3] - coordinates[0],
                coordinates[2] - coordinates[1],
                coordinates[3] - coordinates[1],
                coordinates[3] - coordinates[2],
            ]
            let scale = edges.map(simd_length).max() ?? 0
            guard scale.isFinite, scale > 0 else { return 0 }
            let determinant = abs(simd_dot(edges[0], simd_cross(edges[1], edges[2])))
            return determinant / (scale * scale * scale)
        case .triangle3:
            let first = coordinates[1] - coordinates[0]
            let second = coordinates[2] - coordinates[0]
            let third = coordinates[2] - coordinates[1]
            let scale = max(
                hypot(first.x, first.y),
                hypot(second.x, second.y),
                hypot(third.x, third.y)
            )
            guard scale.isFinite, scale > 0 else { return 0 }
            let twiceArea = abs(first.x * second.y - first.y * second.x)
            return twiceArea / (scale * scale)
        }
    }
}

extension Mesh {
    private enum CodingKeys: String, CodingKey {
        case nodes
        case elements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nodes = try container.decode([SIMD3<Double>].self, forKey: .nodes)
        let elements = try container.decode([Element].self, forKey: .elements)
        try self.init(nodes: nodes, elements: elements)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(elements, forKey: .elements)
    }
}

public struct SurfaceMesh: Sendable {
    public let positions: [SIMD3<Float>]
    public let normals: [SIMD3<Float>]
    public let indices: [UInt32]
    public let sourceNodes: [Int]
    public let triangleCount: Int

    public init(
        faces: [[Int]],
        nodes: [SIMD3<Double>],
        normalsFromFaces: Bool
    ) throws {
        guard !faces.isEmpty else {
            throw MeshError.emptySurface
        }

        for face in faces {
            guard face.count == 3 else {
                throw MeshError.invalidSurfaceVertexCount
            }
            if let invalid = face.first(where: { !nodes.indices.contains($0) }) {
                throw MeshError.invalidSurfaceNode(invalid)
            }
        }
        guard nodes.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw MeshError.invalidSurfaceVertexCount
        }

        var usedNodes = Set<Int>()
        for face in faces {
            usedNodes.formUnion(face)
        }
        let sourceNodes = usedNodes.sorted()
        var localIndex: [Int: Int] = [:]
        localIndex.reserveCapacity(sourceNodes.count)
        for (index, node) in sourceNodes.enumerated() {
            localIndex[node] = index
        }

        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(sourceNodes.count)
        for node in sourceNodes {
            let position = nodes[node]
            positions.append(SIMD3<Float>(
                Float(position.x),
                Float(position.y),
                Float(position.z)
            ))
        }

        var indices = [UInt32]()
        indices.reserveCapacity(faces.count * 3)
        for face in faces {
            indices.append(UInt32(localIndex[face[0]]!))
            indices.append(UInt32(localIndex[face[1]]!))
            indices.append(UInt32(localIndex[face[2]]!))
        }

        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        if normalsFromFaces {
            for face in faces {
                let i0 = localIndex[face[0]]!
                let i1 = localIndex[face[1]]!
                let i2 = localIndex[face[2]]!
                let normal = simd_cross(
                    positions[i1] - positions[i0],
                    positions[i2] - positions[i0]
                )
                normals[i0] += normal
                normals[i1] += normal
                normals[i2] += normal
            }
        } else {
            normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: positions.count)
        }

        for index in normals.indices {
            let length = simd_length(normals[index])
            if length > .ulpOfOne {
                normals[index] /= length
            } else {
                normals[index] = SIMD3<Float>(0, 0, 1)
            }
        }

        self.positions = positions
        self.normals = normals
        self.indices = indices
        self.sourceNodes = sourceNodes
        self.triangleCount = faces.count
    }

    public init(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        indices: [UInt32],
        sourceNodes: [Int]
    ) throws {
        guard positions.count == normals.count,
              positions.count == sourceNodes.count,
              indices.count.isMultiple(of: 3) else {
            throw MeshError.invalidSurfaceVertexCount
        }
        guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              normals.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw MeshError.invalidSurfaceVertexCount
        }
        if let invalid = sourceNodes.first(where: { $0 < 0 }) {
            throw MeshError.invalidSurfaceNode(invalid)
        }
        if let invalid = indices.first(where: { Int($0) >= positions.count }) {
            throw MeshError.invalidSurfaceIndex(invalid)
        }
        self.positions = positions
        self.normals = normals
        self.indices = indices
        self.sourceNodes = sourceNodes
        self.triangleCount = indices.count / 3
    }
}
