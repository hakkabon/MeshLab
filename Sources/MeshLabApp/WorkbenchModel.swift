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
    case productionLinear(ProductionLinearResult)
    case nonlinear(NonlinearStaticResult)
    case coupled(CoupledThermoMechanicalResult)
    case modal(ModalResult)
    case thermal(thermal: ThermalResult, stress: StaticResult)
}

@MainActor
final class WorkbenchModel: ObservableObject {
    @Published var project: MeshLabProject {
        didSet {
            if !project.hasSameAnalysis(as: oldValue) {
                needsSolve = true
                clearDesign()
                cancelDesign()
            }
            if project.designStudy != oldValue.designStudy {
                clearDesign()
                cancelDesign()
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
    @Published private(set) var linearResult: ProductionLinearResult?
    @Published private(set) var nonlinearResult: NonlinearStaticResult?
    @Published private(set) var coupledResult: CoupledThermoMechanicalResult?
    @Published private(set) var scene: RenderScene?
    @Published private(set) var designResult: DesignRunResult?
    @Published private(set) var isSolving = false
    @Published private(set) var isDesigning = false
    @Published private(set) var lastDesignSeconds: Double?
    @Published private(set) var needsSolve = true
    @Published private(set) var selection: SurfacePick?
    @Published private(set) var lastSolveSeconds: Double?
    @Published var errorMessage: String?
    @Published var gmshImportUnit: MeshLengthUnit = .meter

    private var solveTask: Task<Void, Never>?
    private var designTask: Task<Void, Never>?
    private var solveGeneration = 0
    private var designGeneration = 0
    private var revision = 0
    private var designMesh: Mesh?
    private var designStaticResult: StaticResult?

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
        designTask?.cancel()
    }

    var renderOptions: RenderOptions {
        RenderOptions(
            showStress: (project.analysis != .modal || designStaticResult != nil)
                && project.showStress,
            deformationScale: project.deformationScale
        )
    }

    var displayMesh: Mesh {
        designMesh ?? project.mesh
    }

    var exportResult: StaticResult? {
        designStaticResult ?? result
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
        guard displayMesh.nodes.indices.contains(node) else { return nil }

        if let designStaticResult,
           designStaticResult.displacements.indices.contains(node),
           designStaticResult.nodalVonMises.indices.contains(node) {
            return NodeInspection(
                node: node,
                surfaceVertex: selection.surfaceVertex,
                position: displayMesh.nodes[node],
                displacement: designStaticResult.displacements[node],
                vonMises: designStaticResult.nodalVonMises[node],
                temperature: nil,
                modeFrequency: nil
            )
        }
        if let mode = selectedMode, mode.displacements.indices.contains(node) {
            return NodeInspection(
                node: node,
                surfaceVertex: selection.surfaceVertex,
                position: displayMesh.nodes[node],
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
            position: displayMesh.nodes[node],
            displacement: result.displacements[node],
            vonMises: result.nodalVonMises[node],
            temperature: thermalResult?.temperatures.indices.contains(node) == true
                ? thermalResult?.temperatures[node]
                : nil,
            modeFrequency: nil
        )
    }

    var hasResults: Bool {
        if designResult != nil { return true }
        switch project.analysis {
        case .staticAnalysis, .thermalStructural, .productionLinear,
             .nonlinearStatic, .coupledThermoMechanical:
            return result != nil
        case .modal:
            return modalResult != nil
        }
    }

    var resultsCSV: String {
        if let designResult {
            return AnalysisResultExport.designCSV(designResult)
        }
        switch project.analysis {
        case .staticAnalysis:
            guard let result else { return "" }
            return AnalysisResultExport.csv(project: project, result: result)
        case .productionLinear:
            guard let linearResult else { return "" }
            return AnalysisResultExport.linearStudyCSV(
                project: project,
                result: linearResult
            )
        case .nonlinearStatic:
            guard let result else { return "" }
            return AnalysisResultExport.csv(project: project, result: result)
        case .coupledThermoMechanical:
            guard let result, let thermalResult else { return "" }
            return AnalysisResultExport.thermalCSV(
                project: project,
                temperatures: thermalResult.temperatures,
                result: result
            )
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
        clearDesign()
        let generation = solveGeneration
        let project = self.project
        let started = Date()
        isSolving = true
        errorMessage = nil

        solveTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try Self.run(project)
                }
                let outcome = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
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

    func runDesign() {
        if project.designStudy.kind == .parametric,
           project.designStudy.parametric.axes.isEmpty {
            let modulus = project.material.youngModulus
            project.designStudy.parametric = ParametricStudy(axes: [
                ParametricAxis(
                    parameter: .youngModulus,
                    values: [0.5 * modulus, modulus, 1.5 * modulus]
                ),
                ParametricAxis(parameter: .loadScale, values: [0.5, 1, 1.5]),
            ])
        }
        designTask?.cancel()
        designGeneration += 1
        let generation = designGeneration
        let project = self.project
        let started = Date()
        isDesigning = true
        errorMessage = nil

        designTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try project.designStudy.run(on: project)
                }
                let outcome = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled,
                      let self,
                      self.designGeneration == generation else {
                    return
                }
                self.applyDesign(outcome, elapsed: Date().timeIntervalSince(started))
            } catch is CancellationError {
                guard let self, self.designGeneration == generation else { return }
                self.isDesigning = false
            } catch {
                guard let self, self.designGeneration == generation else { return }
                self.isDesigning = false
                self.errorMessage = "Design study failed: \(Self.describe(error))"
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
            if url.pathExtension.lowercased() == "msh" {
                let imported = try GmshImporter.decode(
                    data,
                    options: GmshImportOptions(sourceLengthUnit: gmshImportUnit)
                )
                project = MeshLabProject(
                    name: url.deletingPathExtension().lastPathComponent,
                    mesh: imported.mesh,
                    meshMetadata: imported.metadata,
                    material: project.material,
                    constraints: []
                )
                clearResults()
                revision += 1
                scene = RenderScene(
                    surface: try imported.mesh.makeSurfaceMesh(),
                    revision: revision
                )
            } else {
                project = try MeshLabProjectFile.decode(data)
                clearResults()
                solve()
            }
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

    func setSelectedLinearResult(_ id: String) {
        guard let selected = linearResult?.result(id: id) else { return }
        project.selectedLinearResultID = id
        result = selected.result
        do {
            revision += 1
            scene = RenderScene(
                surface: try project.mesh.makeSurfaceMesh(),
                result: selected.result,
                revision: revision
            )
            selection = nil
        } catch {
            errorMessage = "Could not prepare the render scene: \(Self.describe(error))"
        }
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

    func setDesignKind(_ kind: DesignStudyKind) {
        guard project.designStudy.kind != kind else { return }
        project.designStudy.kind = kind
        if kind == .shape {
            let lastAxis = max(project.mesh.dimension - 1, 0)
            project.designStudy.shape.selectionAxis = min(
                project.designStudy.shape.selectionAxis,
                lastAxis
            )
            project.designStudy.shape.motionAxis = min(
                project.designStudy.shape.motionAxis,
                lastAxis
            )
        }
    }

    func setTopologyVolumeFraction(_ value: Double) {
        project.designStudy.topology.volumeFraction = min(max(value, 0.05), 0.95)
    }

    func setTopologyOuterIterations(_ count: Int) {
        project.designStudy.topology.outerIterations = min(max(count, 1), 12)
    }

    func setTopologyInnerIterations(_ count: Int) {
        project.designStudy.topology.innerIterations = min(max(count, 1), 100)
    }

    func setShapeSelectionAxis(_ axis: Int) {
        let lastAxis = max(project.mesh.dimension - 1, 0)
        project.designStudy.shape.selectionAxis = min(max(axis, 0), lastAxis)
    }

    func setShapeMotionAxis(_ axis: Int) {
        let lastAxis = max(project.mesh.dimension - 1, 0)
        project.designStudy.shape.motionAxis = min(max(axis, 0), lastAxis)
    }

    func setShapeMargin(_ margin: Double) {
        project.designStudy.shape.margin = min(max(margin, 0.01), 1)
    }

    func setShapeOuterIterations(_ count: Int) {
        project.designStudy.shape.outerIterations = min(max(count, 1), 12)
    }

    func setShapeInnerIterations(_ count: Int) {
        project.designStudy.shape.innerIterations = min(max(count, 1), 100)
    }

    func setShowStress(_ show: Bool) {
        project.showStress = show
    }

    func setDeformationScale(_ scale: Float) {
        project.deformationScale = min(max(scale, 0), 10_000)
    }

    func setUseMatrixFree(_ enabled: Bool) {
        project.useMatrixFree = enabled
    }

    func setMatrixFreeIterations(_ count: Int) {
        project.matrixFreeOptions.maximumIterations = min(max(count, 1), 20_000)
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
                linearResult = nil
                nonlinearResult = nil
                coupledResult = nil
                scene = RenderScene(
                    surface: surface,
                    result: staticResult,
                    revision: revision
                )
            case .productionLinear(let production):
                linearResult = production
                modalResult = nil
                thermalResult = nil
                let selected = production.result(id: project.selectedLinearResultID)
                project.selectedLinearResultID = selected?.id
                result = selected?.result
                scene = selected.map {
                    RenderScene(surface: surface, result: $0.result, revision: revision)
                } ?? RenderScene(surface: surface, revision: revision)
                nonlinearResult = nil
                coupledResult = nil
            case .nonlinear(let nonlinear):
                nonlinearResult = nonlinear
                coupledResult = nil
                linearResult = nil
                modalResult = nil
                thermalResult = nil
                result = nonlinear.staticResult
                scene = RenderScene(
                    surface: surface,
                    result: nonlinear.staticResult,
                    revision: revision
                )
            case .coupled(let coupled):
                coupledResult = coupled
                nonlinearResult = nil
                linearResult = nil
                modalResult = nil
                thermalResult = coupled.thermalResult
                result = coupled.staticResult
                scene = RenderScene(
                    surface: surface,
                    result: coupled.staticResult,
                    revision: revision
                )
            case .modal(let modalResult):
                self.modalResult = modalResult
                result = nil
                thermalResult = nil
                linearResult = nil
                nonlinearResult = nil
                coupledResult = nil
                if !modalResult.modes.indices.contains(project.selectedMode) {
                    project.selectedMode = 0
                }
                scene = makeModalScene(surface: surface, modalResult: modalResult)
            case .thermal(let thermalResult, let stress):
                self.thermalResult = thermalResult
                self.result = stress
                modalResult = nil
                linearResult = nil
                nonlinearResult = nil
                coupledResult = nil
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

    private func applyDesign(_ outcome: DesignRunResult, elapsed: Double) {
        do {
            designResult = outcome
            designStaticResult = nil
            designMesh = nil
            revision += 1

            switch outcome {
            case .parametric(let parametric):
                let surface = try parametric.bestModel.mesh.makeSurfaceMesh()
                designMesh = parametric.bestModel.mesh
                designStaticResult = parametric.bestResult
                scene = RenderScene(
                    surface: surface,
                    result: parametric.bestResult,
                    revision: revision
                )
            case .topology(let topology):
                let surface = try project.mesh.makeSurfaceMesh()
                designMesh = project.mesh
                designStaticResult = topology.finalResult
                scene = RenderScene(
                    surface: surface,
                    result: topology.finalResult,
                    revision: revision
                )
            case .shape(let shape):
                let surface = try shape.mesh.makeSurfaceMesh()
                designMesh = shape.mesh
                designStaticResult = shape.staticResult
                scene = RenderScene(
                    surface: surface,
                    result: shape.staticResult,
                    revision: revision
                )
            }

            lastDesignSeconds = elapsed
            selection = nil
            isDesigning = false
        } catch {
            isDesigning = false
            errorMessage = "Could not prepare the design scene: \(Self.describe(error))"
        }
    }

    private func clearDesign() {
        designResult = nil
        designStaticResult = nil
        designMesh = nil
        lastDesignSeconds = nil
    }

    private func cancelDesign() {
        designTask?.cancel()
        designTask = nil
        designGeneration += 1
        isDesigning = false
    }

    private func clearResults() {
        result = nil
        modalResult = nil
        thermalResult = nil
        linearResult = nil
        nonlinearResult = nil
        coupledResult = nil
        scene = nil
        selection = nil
        needsSolve = true
        clearDesign()
    }

    nonisolated private static func run(_ project: MeshLabProject) throws -> SolveOutcome {
        switch project.analysis {
        case .staticAnalysis:
            let result = try StaticAnalysis(options: project.makeAnalysisOptions())
                .solve(project.makeModel())
            return .staticResult(result)

        case .productionLinear:
            return .productionLinear(try ProductionLinearAnalysis.solve(project: project))

        case .nonlinearStatic:
            return .nonlinear(
                try NonlinearStaticAnalysis(options: project.nonlinearOptions)
                    .solve(project.makeModel())
            )

        case .coupledThermoMechanical:
            return .coupled(try CoupledThermoMechanicalAnalysis(
                options: project.coupledOptions,
                analysisOptions: project.makeAnalysisOptions(),
                referenceTemperature: project.thermalStudy.referenceTemperature
            ).solve(
                thermal: project.makeThermalModel(),
                structural: project.makeModel()
            ))

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
            && meshMetadata == other.meshMetadata
            && material == other.material
            && constraints == other.constraints
            && loads == other.loads
            && bodyForce == other.bodyForce
            && loadScale == other.loadScale
            && solverMethod == other.solverMethod
            && directSettings == other.directSettings
            && useMatrixFree == other.useMatrixFree
            && matrixFreeOptions == other.matrixFreeOptions
            && analysis == other.analysis
            && modalModeCount == other.modalModeCount
            && thermalStudy == other.thermalStudy
            && linearStudy == other.linearStudy
            && nonlinearOptions == other.nonlinearOptions
            && coupledOptions == other.coupledOptions
    }
}
