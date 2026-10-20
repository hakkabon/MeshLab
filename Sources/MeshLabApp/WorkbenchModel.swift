import Combine
import Foundation
import MeshLab

struct NodeInspection: Identifiable {
    var id: Int { node }
    let node: Int
    let surfaceVertex: Int
    let position: SIMD3<Double>
    let displacement: SIMD3<Double>
    let vonMises: Double
}

@MainActor
final class WorkbenchModel: ObservableObject {
    @Published var project: MeshLabProject {
        didSet {
            guard !project.hasSameAnalysis(as: oldValue) else { return }
            needsSolve = true
        }
    }
    @Published private(set) var result: StaticResult?
    @Published private(set) var scene: RenderScene?
    @Published private(set) var isSolving = false
    @Published private(set) var needsSolve = true
    @Published private(set) var selection: SurfacePick?
    @Published private(set) var lastSolveSeconds: Double?
    @Published var errorMessage: String?

    private var solveTask: Task<Void, Never>?
    private var solveGeneration = 0
    private var revision = 0

    init() {
        do {
            project = try MeshLabProject.cantileverExample()
        } catch {
            project = Self.fallbackProject
            errorMessage = "Could not create the starter model: \(error)"
        }
    }

    deinit {
        solveTask?.cancel()
    }

    var renderOptions: RenderOptions {
        RenderOptions(
            showStress: project.showStress,
            deformationScale: project.deformationScale
        )
    }

    var solverPreset: SolverPreset {
        SolverPreset(method: project.solverMethod)
    }

    var inspection: NodeInspection? {
        guard let selection, let result else { return nil }
        let node = selection.sourceNode
        guard project.mesh.nodes.indices.contains(node),
              result.displacements.indices.contains(node),
              result.nodalVonMises.indices.contains(node) else {
            return nil
        }
        return NodeInspection(
            node: node,
            surfaceVertex: selection.surfaceVertex,
            position: project.mesh.nodes[node],
            displacement: result.displacements[node],
            vonMises: result.nodalVonMises[node]
        )
    }

    func solveIfNeeded() {
        guard result == nil, !isSolving else { return }
        solve()
    }

    func solve() {
        solveTask?.cancel()
        solveGeneration += 1
        let generation = solveGeneration
        let project = self.project
        let started = Date()
        isSolving = true
        errorMessage = nil

        solveTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try StaticAnalysis(options: project.makeAnalysisOptions())
                        .solve(project.makeModel())
                }.value
                guard !Task.isCancelled, let self, self.solveGeneration == generation else {
                    return
                }
                self.apply(result, project: project, elapsed: Date().timeIntervalSince(started))
            } catch is CancellationError {
                guard let self, self.solveGeneration == generation else { return }
                self.isSolving = false
            } catch {
                guard let self, self.solveGeneration == generation else { return }
                self.isSolving = false
                self.errorMessage = Self.describe(error)
            }
        }
    }

    func loadCantileverExample() {
        do {
            project = try MeshLabProject.cantileverExample()
            result = nil
            scene = nil
            selection = nil
            needsSolve = true
            solve()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func importProject(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: url)
            project = try MeshLabProjectFile.decode(data)
            result = nil
            scene = nil
            selection = nil
            needsSolve = true
            solve()
        } catch {
            errorMessage = "Import failed: \(Self.describe(error))"
        }
    }

    func exportProject(to url: URL) -> Bool {
        do {
            try MeshLabProjectFile.encode(project).write(to: url, options: .atomic)
            return true
        } catch {
            errorMessage = "Export failed: \(Self.describe(error))"
            return false
        }
    }

    func exportResults(to url: URL) -> Bool {
        guard let result else {
            errorMessage = "Run an analysis before exporting results."
            return false
        }
        do {
            try AnalysisResultExport.csv(project: project, result: result)
                .write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            errorMessage = "Export failed: \(Self.describe(error))"
            return false
        }
    }

    func select(_ pick: SurfacePick?) {
        selection = pick
    }

    func setSolverPreset(_ preset: SolverPreset) {
        project.solverMethod = preset.method
    }

    func setOrdering(_ ordering: SparseOrderingKind) {
        project.directSettings.ordering = ordering
    }

    func setRefinementSteps(_ steps: Int) {
        project.directSettings.refinementSteps = max(0, min(10, steps))
    }

    func setYoungModulus(_ value: Double) {
        updateMaterial(youngModulus: value)
    }

    func setPoissonRatio(_ value: Double) {
        updateMaterial(poissonRatio: value)
    }

    func setDensity(_ value: Double) {
        updateMaterial(density: value)
    }

    func setLoadScale(_ value: Double) {
        project.loadScale = value
    }

    func setShowStress(_ show: Bool) {
        project.showStress = show
    }

    func setDeformationScale(_ scale: Float) {
        project.deformationScale = min(max(scale, 0), 10_000)
    }

    private func updateMaterial(
        youngModulus: Double? = nil,
        poissonRatio: Double? = nil,
        density: Double? = nil
    ) {
        do {
            project.material = try ElasticMaterial(
                youngModulus: youngModulus ?? project.material.youngModulus,
                poissonRatio: poissonRatio ?? project.material.poissonRatio,
                density: density ?? project.material.density,
                planeKinematics: project.material.planeKinematics,
                thickness: project.material.thickness
            )
        } catch {
            errorMessage = "Material is invalid: \(Self.describe(error))"
        }
    }

    private func apply(_ result: StaticResult, project: MeshLabProject, elapsed: Double) {
        do {
            let surface = try project.mesh.makeSurfaceMesh()
            revision += 1
            self.result = result
            self.scene = RenderScene(surface: surface, result: result, revision: revision)
            self.lastSolveSeconds = elapsed
            self.selection = nil
            self.needsSolve = false
            self.isSolving = false
        } catch {
            self.isSolving = false
            self.errorMessage = "Could not prepare the render scene: \(Self.describe(error))"
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private static var fallbackProject: MeshLabProject {
        let nodes = [
            SIMD3<Double>(0, 0, 0),
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, 1, 0),
            SIMD3<Double>(0, 0, 1),
        ]
        let mesh = try! Mesh(
            nodes: nodes,
            elements: [Element(type: .tetrahedron4, nodes: [0, 1, 2, 3])]
        )
        let material = try! ElasticMaterial(youngModulus: 1e9, poissonRatio: 0.25)
        return MeshLabProject(
            name: "Fallback",
            mesh: mesh,
            material: material,
            constraints: [DirichletCondition.fixed(node: 0)]
        )
    }
}

enum SolverPreset: String, CaseIterable, Identifiable {
    case automatic
    case accelerateLDLT
    case accelerateCholesky
    case numericCoreLDLT
    case numericCoreLU
    case numericCoreCholesky
    case conjugateGradient
    case biCGSTAB
    case gmres

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .accelerateLDLT: return "Accelerate LDLT"
        case .accelerateCholesky: return "Accelerate Cholesky"
        case .numericCoreLDLT: return "NumericCore LDLT"
        case .numericCoreLU: return "NumericCore LU"
        case .numericCoreCholesky: return "NumericCore Cholesky"
        case .conjugateGradient: return "Conjugate Gradient"
        case .biCGSTAB: return "BiCGSTAB"
        case .gmres: return "GMRES"
        }
    }

    var method: SparseSolverMethod {
        switch self {
        case .automatic: return .automatic
        case .accelerateLDLT: return .accelerateLDLT
        case .accelerateCholesky: return .accelerateCholesky
        case .numericCoreLDLT: return .numericCoreLDLT
        case .numericCoreLU: return .numericCoreLU
        case .numericCoreCholesky: return .numericCoreCholesky
        case .conjugateGradient: return .conjugateGradient(SparseIterativeSettings(
            maxIterations: 5_000,
            tolerance: 1e-10,
            preconditioner: .jacobi
        ))
        case .biCGSTAB: return .biCGSTAB(SparseIterativeSettings(
            maxIterations: 5_000,
            tolerance: 1e-10,
            preconditioner: .ilu0
        ))
        case .gmres: return .gmres(
            restart: 30,
            settings: SparseIterativeSettings(
                maxIterations: 5_000,
                tolerance: 1e-10,
                preconditioner: .ilu0
            )
        )
        }
    }

    init(method: SparseSolverMethod) {
        switch method {
        case .automatic: self = .automatic
        case .accelerateLDLT: self = .accelerateLDLT
        case .accelerateCholesky: self = .accelerateCholesky
        case .numericCoreLDLT: self = .numericCoreLDLT
        case .numericCoreLU: self = .numericCoreLU
        case .numericCoreCholesky: self = .numericCoreCholesky
        case .conjugateGradient: self = .conjugateGradient
        case .biCGSTAB: self = .biCGSTAB
        case .gmres: self = .gmres
        }
    }
}

private extension MeshLabProject {
    func hasSameAnalysis(as other: MeshLabProject) -> Bool {
        mesh == other.mesh
            && material == other.material
            && constraints == other.constraints
            && loads == other.loads
            && bodyForce == other.bodyForce
            && loadScale == other.loadScale
            && solverMethod == other.solverMethod
            && directSettings == other.directSettings
    }
}
