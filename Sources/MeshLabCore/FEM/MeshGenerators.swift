import Foundation
import simd

public enum MeshGenerators {
    /// Structured tetrahedral mesh of an axis-aligned box.
    ///
    /// Each hexahedral cell is split into six tetrahedra along its
    /// `0-6` body diagonal. Using the same relative diagonal in every cell
    /// keeps shared faces conforming.
    public static func structuredBox(
        size: SIMD3<Double>,
        divisions: SIMD3<Int>
    ) throws -> Mesh {
        guard size.x > 0, size.y > 0, size.z > 0,
              divisions.x > 0, divisions.y > 0, divisions.z > 0 else {
            throw FEMError.invalidModel("Box size and divisions must be positive")
        }

        let nx = divisions.x
        let ny = divisions.y
        let nz = divisions.z
        let dx = size.x / Double(nx)
        let dy = size.y / Double(ny)
        let dz = size.z / Double(nz)

        var nodes: [SIMD3<Double>] = []
        nodes.reserveCapacity((nx + 1) * (ny + 1) * (nz + 1))
        for k in 0...nz {
            for j in 0...ny {
                for i in 0...nx {
                    nodes.append(SIMD3<Double>(
                        Double(i) * dx,
                        Double(j) * dy,
                        Double(k) * dz
                    ))
                }
            }
        }

        func node(_ i: Int, _ j: Int, _ k: Int) -> Int {
            (k * (ny + 1) + j) * (nx + 1) + i
        }

        var elements: [Element] = []
        elements.reserveCapacity(nx * ny * nz * 6)

        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx {
                    let v = [
                        node(i, j, k),
                        node(i + 1, j, k),
                        node(i + 1, j + 1, k),
                        node(i, j + 1, k),
                        node(i, j, k + 1),
                        node(i + 1, j, k + 1),
                        node(i + 1, j + 1, k + 1),
                        node(i, j + 1, k + 1),
                    ]

                    let cells = [
                        [0, 1, 2, 6],
                        [0, 2, 3, 6],
                        [0, 3, 7, 6],
                        [0, 7, 4, 6],
                        [0, 4, 5, 6],
                        [0, 5, 1, 6],
                    ]

                    for cell in cells {
                        var connectivity = cell.map { v[$0] }
                        let p0 = nodes[connectivity[0]]
                        let p1 = nodes[connectivity[1]]
                        let p2 = nodes[connectivity[2]]
                        let p3 = nodes[connectivity[3]]
                        let volume = simd_dot(p1 - p0, simd_cross(p2 - p0, p3 - p0))
                        if volume < 0 {
                            connectivity.swapAt(1, 2)
                        }
                        elements.append(Element(
                            type: .tetrahedron4,
                            nodes: connectivity
                        ))
                    }
                }
            }
        }

        return try Mesh(nodes: nodes, elements: elements)
    }

    /// Structured triangle mesh of a rectangle in the XY plane.
    public static func structuredRectangle(
        width: Double,
        height: Double,
        divisions: SIMD2<Int>
    ) throws -> Mesh {
        guard width > 0, height > 0, divisions.x > 0, divisions.y > 0 else {
            throw FEMError.invalidModel("Rectangle size and divisions must be positive")
        }

        let nx = divisions.x
        let ny = divisions.y
        let dx = width / Double(nx)
        let dy = height / Double(ny)

        var nodes: [SIMD3<Double>] = []
        nodes.reserveCapacity((nx + 1) * (ny + 1))
        for j in 0...ny {
            for i in 0...nx {
                nodes.append(SIMD3<Double>(
                    Double(i) * dx,
                    Double(j) * dy,
                    0
                ))
            }
        }

        func node(_ i: Int, _ j: Int) -> Int {
            j * (nx + 1) + i
        }

        var elements: [Element] = []
        elements.reserveCapacity(nx * ny * 2)
        for j in 0..<ny {
            for i in 0..<nx {
                let v0 = node(i, j)
                let v1 = node(i + 1, j)
                let v2 = node(i + 1, j + 1)
                let v3 = node(i, j + 1)
                elements.append(Element(type: .triangle3, nodes: [v0, v1, v2]))
                elements.append(Element(type: .triangle3, nodes: [v0, v2, v3]))
            }
        }

        return try Mesh(nodes: nodes, elements: elements)
    }
}
