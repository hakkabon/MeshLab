import Foundation
import simd

public enum MeshLabProjectError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

/// A portable, editable analysis project.
///
/// The project owns the mesh and analysis definition. Display settings travel
/// with the document so reopening a project restores the same review state.
public struct MeshLabProject: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var name: String
    public var mesh: Mesh
    public var material: ElasticMaterial
    public var constraints: [DirichletCondition]
    public var loads: [Load]
    public var bodyForce: SIMD3<Double>
    public var loadScale: Double
    public var solverMethod: SparseSolverMethod
    public var directSettings: SparseDirectSettings
    public var showStress: Bool
    public var deformationScale: Float

    public init(
        name: String = "Untitled",
        mesh: Mesh,
        material: ElasticMaterial,
        constraints: [DirichletCondition],
        loads: [Load] = [],
        bodyForce: SIMD3<Double> = .zero,
        loadScale: Double = 1,
        solverMethod: SparseSolverMethod = .automatic,
        directSettings: SparseDirectSettings = SparseDirectSettings(),
        showStress: Bool = true,
        deformationScale: Float = 1
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.mesh = mesh
        self.material = material
        self.constraints = constraints
        self.loads = loads
        self.bodyForce = bodyForce
        self.loadScale = loadScale
        self.solverMethod = solverMethod
        self.directSettings = directSettings
        self.showStress = showStress
        self.deformationScale = deformationScale
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case name
        case mesh
        case material
        case constraints
        case loads
        case bodyForce
        case loadScale
        case solverMethod
        case directSettings
        case showStress
        case deformationScale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw MeshLabProjectError.unsupportedSchemaVersion(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.name = try container.decode(String.self, forKey: .name)
        self.mesh = try container.decode(Mesh.self, forKey: .mesh)
        self.material = try container.decode(ElasticMaterial.self, forKey: .material)
        self.constraints = try container.decode([DirichletCondition].self, forKey: .constraints)
        self.loads = try container.decode([Load].self, forKey: .loads)
        self.bodyForce = try container.decode(SIMD3<Double>.self, forKey: .bodyForce)
        self.loadScale = try container.decode(Double.self, forKey: .loadScale)
        self.solverMethod = try container.decode(SparseSolverMethod.self, forKey: .solverMethod)
        self.directSettings = try container.decode(SparseDirectSettings.self, forKey: .directSettings)
        self.showStress = try container.decode(Bool.self, forKey: .showStress)
        self.deformationScale = try container.decode(Float.self, forKey: .deformationScale)
    }

    public func makeModel() -> FEMModel {
        FEMModel(
            mesh: mesh,
            material: material,
            constraints: constraints,
            loads: loads.map { $0.scaled(by: loadScale) },
            bodyForce: bodyForce * loadScale
        )
    }

    public func makeAnalysisOptions() -> AnalysisOptions {
        AnalysisOptions(
            solverMethod: solverMethod,
            directSettings: directSettings
        )
    }

    public static func cantileverExample() throws -> MeshLabProject {
        let mesh = try MeshGenerators.structuredBox(
            size: SIMD3<Double>(1, 1, 4),
            divisions: SIMD3<Int>(2, 2, 8)
        )
        let material = try ElasticMaterial(
            youngModulus: 200e9,
            poissonRatio: 0.3,
            density: 7800
        )
        let constraints = mesh.nodeIndices { abs($0.z) < 1e-12 }
            .map { DirichletCondition.fixed(node: $0) }
        let loads = mesh.nodeIndices { abs($0.z - 4) < 1e-9 }
            .map { Load.nodal(node: $0, vector: SIMD3<Double>(0, 0, -10_000)) }

        return MeshLabProject(
            name: "Cantilever",
            mesh: mesh,
            material: material,
            constraints: constraints,
            loads: loads,
            solverMethod: .automatic,
            deformationScale: 1_000
        )
    }
}

private extension Load {
    func scaled(by factor: Double) -> Load {
        switch self {
        case .nodal(let node, let vector):
            return .nodal(node: node, vector: vector * factor)
        case .traction(let nodes, let vector):
            return .traction(nodes: nodes, vector: vector * factor)
        }
    }
}

public enum MeshLabProjectFile {
    public static func encode(_ project: MeshLabProject) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }

    public static func decode(_ data: Data) throws -> MeshLabProject {
        try JSONDecoder().decode(MeshLabProject.self, from: data)
    }
}

public enum AnalysisResultExport {
    /// Exports nodal displacements and von Mises stress as CSV.
    public static func csv(project: MeshLabProject, result: StaticResult) -> String {
        var rows = [
            "node,x,y,z,ux,uy,uz,vonMises",
        ]
        rows.reserveCapacity(project.mesh.nodes.count + 1)
        for node in project.mesh.nodes.indices {
            let position = project.mesh.nodes[node]
            let displacement = result.displacements[node]
            rows.append([
                String(node),
                number(position.x),
                number(position.y),
                number(position.z),
                number(displacement.x),
                number(displacement.y),
                number(displacement.z),
                number(result.nodalVonMises[node]),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
