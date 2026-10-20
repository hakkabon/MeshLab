import Combine
import Foundation
import MeshLab

struct NodeInspection: Identifiable {
    var id: Int { node }
    let node: Int
    let surfaceVertex: Int
    let position: SIMD3<Double>
    let displacement: SIMD3<Double>
    let vonMises: Double?
    let temperature: Double?
    let modeFrequency: Double?
}

private enum SolveOutcome: Sendable {
    case staticResult(StaticResult)
    case modal(ModalResult)
    case thermal(thermal: ThermalResult, stress: StaticResult)
}

@MainActor
final class WorkbenchModel: ObservableObject {
    @Published var project: MeshLabProject {
        didSet {
            if !project.hasSameAnalysis(as: oldValue) {
                needsSolve = true
            }
            if project.analysis == .modal,
               project.selectedMode != oldValue.selectedMode {
                refreshModalScene()
            }
        }
    }
    @Published private(set) var result: StaticResult?
    @Published private(set) var modalResult: ModalResult?
    @Published private(set) var thermalResult: ThermalResult?
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
            showStress: project.analysis != .modal && project.showStress,
            deformationScale: project.deformationScale
        )
    }

    var solverPreset: SolverPreset {
        SolverPreset(method: project.solverMethod)
    }

    var selectedMode: VibrationMode? {
        guard project.analysis == .modal,
              let modalResult,
              modalResult.modes.indices.contains(project.selectedMode) else {
            return nil
        }
        return modalResult.modes[project.selectedMode]
    }

    var inspection: NodeInspection? {
        guard let selection else { return nil }
        let node = selection.sourceNode
        guard project.mesh.nodes.indices.contains(node) else { return nil }

        if let mode = selectedMode, mode.displacements.indices.contains(node) {
            return NodeInspection(
                node: node,
                surfaceVertex: selection.surfaceVertex,
                position: project.mesh.nodes[node],
                displacement: mode.displacements[node],
                vonMises: nil,
                temperature: nil,
                modeFrequency: mode.frequencyHz
            )
        }
        guard let result,
              result.displacements.indices.contains(node),
              result.nodalVonMises.indices.contains(node) else {
            return nil
        }
        return NodeInspection(
            node: node,
            surfaceVertex: selection.surfaceVertex,
            position: project.mesh.nodes[node],
            displacement: result.displacements[node],
            vonMises: result.nodalVonMises[node],
            temperature: thermalResult?.temperatures.indices.contains(node) == true
                ? thermalResult?.temperatures[node]
                : nil,
            modeFrequency: nil
        )
    }

    var hasResults: Bool {
        switch project.analysis {
        case .staticAnalysis, .thermalStructural:
            return result != nil
        case .modal:
            return modalResult != nil
        }
    }

    var resultsCSV: String {
        switch project.analysis {
        case .staticAnalysis:
            guard let result else { return "" }
            return AnalysisResultExport.csv(project: project, result: result)
        case .modal:
            guard let modalResult else { return "" }
            return AnalysisResultExport.modalCSV(project: project, result: modalResult)
        case .thermalStructural:
            guard let result, let thermalResult else { return "" }
            return AnalysisResultExport.thermalCSV(
                project: project,
                temperatures: thermalResult.temperatures,
                result: result
            )
        }
    }

    func solveIfNeeded() {
        guard needsSolve, !isSolving else { return }
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
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try Self.run(project)
                }.value
                guard !Task.isCancelled, let self, self.solveGeneration == generation else {
                    return
                }
                self.apply(outcome, elapsed: Date().timeIntervalSince(started))
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
            clearResults()
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
            clearResults()
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
        guard !resultsCSV.isEmpty else {
            errorMessage = "Run an analysis before exporting results."
            return false
        }
        do {
            try resultsCSV.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            errorMessage = "Export failed: \(Self.describe(error))"
            return false
        }
    }

    func select(_ pick: SurfacePick?) {
        selection = pick
    }

    func setAnalysis(_ analysis: AnalysisKind) {
        guard project.analysis != analysis else { return }
        project.analysis = analysis
        clearResults()
        solve()
    }

    func setModalModeCount(_ count: Int) {
        project.modalModeCount = min(max(count, 1), 50)
    }

    func setSelectedMode(_ index: Int) {
        guard let modalResult, !modalResult.modes.isEmpty else { return }
        project.selectedMode = min(max(index, 0), modalResult.modes.count - 1)
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

    func setThermalConductivity(_ value: Double) {
        updateMaterial(thermalConductivity: value)
    }

    func setThermalExpansion(_ value: Double) {
        updateMaterial(thermalExpansion: value)
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
        density: Double? = nil,
        thermalConductivity: Double? = nil,
        thermalExpansion: Double? = nil
    ) {
        do {
            project.material = try ElasticMaterial(
                youngModulus: youngModulus ?? project.material.youngModulus,
                poissonRatio: poissonRatio ?? project.material.poissonRatio,
                density: density ?? project.material.density,
                planeKinematics: project.material.planeKinematics,
                thickness: project.material.thickness,
                thermalConductivity: thermalConductivity
                    ?? project.material.thermalConductivity,
                thermalExpansion: thermalExpansion
                    ?? project.material.thermalExpansion
            )
        } catch {
            errorMessage = "Material is invalid: \(Self.describe(error))"
        }
    }

    private func apply(_ outcome: SolveOutcome, elapsed: Double) {
        do {
            let surface = try project.mesh.makeSurfaceMesh()
            revision += 1

            switch outcome {
            case .staticResult(let staticResult):
                result = staticResult
                modalResult = nil
                thermalResult = nil
                scene = RenderScene(
                    surface: surface,
                    result: staticResult,
                    revision: revision
                )
            case .modal(let modalResult):
                self.modalResult = modalResult
                result = nil
                thermalResult = nil
                if !modalResult.modes.indices.contains(project.selectedMode) {
                    project.selectedMode = 0
                }
                scene = makeModalScene(surface: surface, modalResult: modalResult)
            case .thermal(let thermalResult, let stress):
                self.thermalResult = thermalResult
                self.result = stress
                modalResult = nil
                scene = RenderScene(
                    surface: surface,
                    result: stress,
                    revision: revision
                )
            }

            lastSolveSeconds = elapsed
            selection = nil
            needsSolve = false
            isSolving = false
        } catch {
            isSolving = false
            errorMessage = "Could not prepare the render scene: \(Self.describe(error))"
        }
    }

    private func refreshModalScene() {
        guard let modalResult else { return }
        do {
            let surface = try project.mesh.makeSurfaceMesh()
            revision += 1
            scene = makeModalScene(surface: surface, modalResult: modalResult)
            selection = nil
        } catch {
            errorMessage = "Could not prepare the render scene: \(Self.describe(error))"
        }
    }

    private func makeModalScene(
        surface: SurfaceMesh,
        modalResult: ModalResult
    ) -> RenderScene? {
        guard modalResult.modes.indices.contains(project.selectedMode) else {
            return RenderScene(surface: surface, revision: revision)
        }
        let mode = modalResult.modes[project.selectedMode]
        return RenderScene(
            surface: surface,
            displacements: mode.displacements,
            scalar: [Double](repeating: 0, count: project.mesh.nodes.count),
            revision: revision
        )
    }

    private func clearResults() {
        result = nil
        modalResult = nil
        thermalResult = nil
        scene = nil
        selection = nil
        needsSolve = true
    }

    nonisolated private static func run(_ project: MeshLabProject) throws -> SolveOutcome {
        switch project.analysis {
        case .staticAnalysis:
            let result = try StaticAnalysis(options: project.makeAnalysisOptions())
                .solve(project.makeModel())
            return .staticResult(result)

        case .modal:
            let result = try ModalAnalysis(options: ModalOptions(
                modeCount: project.modalModeCount
            )).solve(project.makeModel())
            return .modal(result)

        case .thermalStructural:
            let thermal = try ThermalAnalysis(options: project.makeAnalysisOptions())
                .solve(project.makeThermalModel())
            let stress = try ThermalStressAnalysis(
                options: project.makeAnalysisOptions(),
                referenceTemperature: project.thermalStudy.referenceTemperature
            ).solve(project.makeModel(), temperatures: thermal.temperatures)
            return .thermal(thermal: thermal, stress: stress.staticResult)
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
            && analysis == other.analysis
            && modalModeCount == other.modalModeCount
            && thermalStudy == other.thermalStudy
    }
}
