import Foundation
import simd

public enum MeshLabProjectError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

public enum AnalysisKind: String, Sendable, Hashable, Codable, CaseIterable {
    case staticAnalysis = "static"
    case productionLinear = "production-linear"
    case modal
    case thermalStructural
}

public struct ThermalStudy: Sendable, Hashable, Codable {
    public var constraints: [ThermalConstraint]
    public var referenceTemperature: Double
    public var nodalHeat: [ThermalLoad]
    public var volumetricHeat: Double

    public init(
        constraints: [ThermalConstraint] = [],
        referenceTemperature: Double = 0,
        nodalHeat: [ThermalLoad] = [],
        volumetricHeat: Double = 0
    ) {
        self.constraints = constraints
        self.referenceTemperature = referenceTemperature
        self.nodalHeat = nodalHeat
        self.volumetricHeat = volumetricHeat
    }
}

/// A portable, editable analysis project.
///
/// The project owns the mesh and analysis definition. Display settings travel
/// with the document so reopening a project restores the same review state.
public struct MeshLabProject: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 6

    public var schemaVersion: Int
    public var name: String
    public var mesh: Mesh
    public var meshMetadata: MeshMetadata
    public var material: ElasticMaterial
    public var constraints: [DirichletCondition]
    public var loads: [Load]
    public var bodyForce: SIMD3<Double>
    public var loadScale: Double
    public var solverMethod: SparseSolverMethod
    public var directSettings: SparseDirectSettings
    public var showStress: Bool
    public var deformationScale: Float
    public var analysis: AnalysisKind
    public var modalModeCount: Int
    public var selectedMode: Int
    public var thermalStudy: ThermalStudy
    public var designStudy: DesignStudy
    public var useMatrixFree: Bool
    public var matrixFreeOptions: MatrixFreeOptions
    public var linearStudy: ProductionLinearStudy
    public var selectedLinearResultID: String?

    public init(
        name: String = "Untitled",
        mesh: Mesh,
        meshMetadata: MeshMetadata = MeshMetadata(),
        material: ElasticMaterial,
        constraints: [DirichletCondition],
        loads: [Load] = [],
        bodyForce: SIMD3<Double> = .zero,
        loadScale: Double = 1,
        solverMethod: SparseSolverMethod = .automatic,
        directSettings: SparseDirectSettings = SparseDirectSettings(),
        showStress: Bool = true,
        deformationScale: Float = 1,
        analysis: AnalysisKind = .staticAnalysis,
        modalModeCount: Int = 6,
        selectedMode: Int = 0,
        thermalStudy: ThermalStudy = ThermalStudy(),
        designStudy: DesignStudy = DesignStudy(),
        useMatrixFree: Bool = false,
        matrixFreeOptions: MatrixFreeOptions = MatrixFreeOptions(),
        linearStudy: ProductionLinearStudy = ProductionLinearStudy(),
        selectedLinearResultID: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.mesh = mesh
        self.meshMetadata = meshMetadata
        self.material = material
        self.constraints = constraints
        self.loads = loads
        self.bodyForce = bodyForce
        self.loadScale = loadScale
        self.solverMethod = solverMethod
        self.directSettings = directSettings
        self.showStress = showStress
        self.deformationScale = deformationScale
        self.analysis = analysis
        self.modalModeCount = modalModeCount
        self.selectedMode = selectedMode
        self.thermalStudy = thermalStudy
        self.designStudy = designStudy
        self.useMatrixFree = useMatrixFree
        self.matrixFreeOptions = matrixFreeOptions
        self.linearStudy = linearStudy
        self.selectedLinearResultID = selectedLinearResultID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case name
        case mesh
        case meshMetadata
        case material
        case constraints
        case loads
        case bodyForce
        case loadScale
        case solverMethod
        case directSettings
        case showStress
        case deformationScale
        case analysis
        case modalModeCount
        case selectedMode
        case thermalStudy
        case designStudy
        case useMatrixFree
        case matrixFreeOptions
        case linearStudy
        case selectedLinearResultID
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
        self.meshMetadata = try container.decodeIfPresent(
            MeshMetadata.self,
            forKey: .meshMetadata
        ) ?? MeshMetadata()
        self.material = try container.decode(ElasticMaterial.self, forKey: .material)
        self.constraints = try container.decode([DirichletCondition].self, forKey: .constraints)
        self.loads = try container.decode([Load].self, forKey: .loads)
        self.bodyForce = try container.decode(SIMD3<Double>.self, forKey: .bodyForce)
        self.loadScale = try container.decode(Double.self, forKey: .loadScale)
        self.solverMethod = try container.decode(SparseSolverMethod.self, forKey: .solverMethod)
        self.directSettings = try container.decode(SparseDirectSettings.self, forKey: .directSettings)
        self.showStress = try container.decode(Bool.self, forKey: .showStress)
        self.deformationScale = try container.decode(Float.self, forKey: .deformationScale)
        self.analysis = try container.decodeIfPresent(
            AnalysisKind.self,
            forKey: .analysis
        ) ?? .staticAnalysis
        self.modalModeCount = try container.decodeIfPresent(
            Int.self,
            forKey: .modalModeCount
        ) ?? 6
        self.selectedMode = try container.decodeIfPresent(
            Int.self,
            forKey: .selectedMode
        ) ?? 0
        self.thermalStudy = try container.decodeIfPresent(
            ThermalStudy.self,
            forKey: .thermalStudy
        ) ?? ThermalStudy()
        self.designStudy = try container.decodeIfPresent(
            DesignStudy.self,
            forKey: .designStudy
        ) ?? DesignStudy()
        self.useMatrixFree = try container.decodeIfPresent(
            Bool.self,
            forKey: .useMatrixFree
        ) ?? false
        self.matrixFreeOptions = try container.decodeIfPresent(
            MatrixFreeOptions.self,
            forKey: .matrixFreeOptions
        ) ?? MatrixFreeOptions()
        self.linearStudy = try container.decodeIfPresent(
            ProductionLinearStudy.self,
            forKey: .linearStudy
        ) ?? ProductionLinearStudy()
        self.selectedLinearResultID = try container.decodeIfPresent(
            String.self,
            forKey: .selectedLinearResultID
        )
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

    public func makeThermalModel() -> ThermalModel {
        ThermalModel(
            mesh: mesh,
            material: material,
            constraints: thermalStudy.constraints,
            nodalHeat: thermalStudy.nodalHeat,
            volumetricHeat: thermalStudy.volumetricHeat
        )
    }

    public func makeThermalStressModel(temperatures: [Double]) -> FEMModel {
        var model = makeModel()
        model.temperatureChange = temperatures.map {
            $0 - thermalStudy.referenceTemperature
        }
        return model
    }

    public func makeAnalysisOptions() -> AnalysisOptions {
        AnalysisOptions(
            solverMethod: solverMethod,
            directSettings: directSettings,
            matrixFreeOptions: useMatrixFree ? matrixFreeOptions : nil
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
            density: 7800,
            thermalConductivity: 45,
            thermalExpansion: 1.2e-5
        )
        let constraints = mesh.nodeIndices { abs($0.z) < 1e-12 }
            .map { DirichletCondition.fixed(node: $0) }
        let loads = mesh.nodeIndices { abs($0.z - 4) < 1e-9 }
            .map { Load.nodal(node: $0, vector: SIMD3<Double>(0, 0, -10_000)) }
        let thermalConstraints = mesh.nodeIndices { abs($0.z) < 1e-12 }
            .map { ThermalConstraint(node: $0, temperature: 20) }
            + mesh.nodeIndices { abs($0.z - 4) < 1e-9 }
            .map { ThermalConstraint(node: $0, temperature: 120) }

        return MeshLabProject(
            name: "Cantilever",
            mesh: mesh,
            material: material,
            constraints: constraints,
            loads: loads,
            solverMethod: .automatic,
            deformationScale: 1_000,
            analysis: .staticAnalysis,
            modalModeCount: 6,
            thermalStudy: ThermalStudy(
                constraints: thermalConstraints,
                referenceTemperature: 20
            ),
            designStudy: DesignStudy(
                kind: .parametric,
                parametric: ParametricStudy(axes: [
                    ParametricAxis(
                        parameter: .youngModulus,
                        values: [100e9, 200e9, 300e9]
                    ),
                    ParametricAxis(
                        parameter: .loadScale,
                        values: [0.5, 1, 1.5]
                    ),
                ])
            )
        )
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

    /// Exports every production load-case and combination result in long form.
    public static func linearStudyCSV(
        project: MeshLabProject,
        result: ProductionLinearResult
    ) -> String {
        var rows = [
            "resultID,resultName,resultKind,node,x,y,z,ux,uy,uz,vonMises",
        ]
        rows.reserveCapacity(result.results.count * project.mesh.nodes.count + 1)
        for value in result.results {
            for node in project.mesh.nodes.indices {
                let position = project.mesh.nodes[node]
                let displacement = value.result.displacements[node]
                rows.append([
                    csvText(value.id),
                    csvText(value.name),
                    value.kind.rawValue,
                    String(node),
                    number(position.x),
                    number(position.y),
                    number(position.z),
                    number(displacement.x),
                    number(displacement.y),
                    number(displacement.z),
                    number(value.result.nodalVonMises[node]),
                ].joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Exports the requested modal frequencies and normalized mode peak.
    public static func modalCSV(project: MeshLabProject, result: ModalResult) -> String {
        var rows = ["mode,frequencyHz,angularFrequency,maxDisplacement"]
        for mode in result.modes {
            let peak = mode.displacements.reduce(0.0) {
                max($0, simd_length($1))
            }
            rows.append([
                String(mode.index + 1),
                number(mode.frequencyHz),
                number(mode.angularFrequency),
                number(peak),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Exports temperatures together with the coupled static stress result.
    public static func thermalCSV(
        project: MeshLabProject,
        temperatures: [Double],
        result: StaticResult
    ) -> String {
        var rows = [
            "node,x,y,z,temperature,ux,uy,uz,vonMises",
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
                number(temperatures[node]),
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

    private static func csvText(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
