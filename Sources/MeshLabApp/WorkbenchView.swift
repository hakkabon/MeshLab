import MeshLab
import SwiftUI
import UniformTypeIdentifiers
import simd

struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchModel

    @State private var isImporting = false
    @State private var isExportingProject = false
    @State private var isExportingResults = false
    @State private var didAutoSolve = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            viewport
        }
        .navigationTitle(model.project.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isImporting = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }

                Menu {
                    Button("Export Project…") {
                        isExportingProject = true
                    }
                    Button("Export Results CSV…") {
                        isExportingResults = true
                    }
                    .disabled(!model.hasResults || model.needsSolve)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Button {
                    model.solve()
                } label: {
                    Label("Solve", systemImage: "play.fill")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isSolving)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.importProject(from: url)
                }
            case .failure(let error):
                model.errorMessage = "Import failed: \(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $isExportingProject,
            document: MeshLabProjectDocument(project: model.project),
            contentType: .json,
            defaultFilename: model.project.name
        ) { result in
            if case .failure(let error) = result {
                model.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $isExportingResults,
            document: ResultsCSVDocument(text: resultsCSV),
            contentType: .commaSeparatedText,
            defaultFilename: "\(model.project.name)-results"
        ) { result in
            if case .failure(let error) = result {
                model.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        .onAppear {
            guard !didAutoSolve else { return }
            didAutoSolve = true
            model.solveIfNeeded()
        }
    }

    private var sidebar: some View {
        Form {
            Section("Project") {
                TextField("Name", text: $model.project.name)
                Button("Reset Cantilever Example") {
                    model.loadCantileverExample()
                }
                LabeledContent("Nodes", value: "\(model.project.mesh.nodes.count)")
                LabeledContent("Elements", value: "\(model.project.mesh.elements.count)")
                LabeledContent("DOFs", value: "\(model.project.mesh.dofCount)")
            }

            Section("Analysis") {
                Picker(
                    "Type",
                    selection: Binding(
                        get: { model.project.analysis },
                        set: { model.setAnalysis($0) }
                    )
                ) {
                    ForEach(AnalysisKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                if model.project.analysis == .modal {
                    Stepper(
                        "Modes: \(model.project.modalModeCount)",
                        value: Binding(
                            get: { model.project.modalModeCount },
                            set: { model.setModalModeCount($0) }
                        ),
                        in: 1...50
                    )
                }
                if model.project.analysis == .thermalStructural {
                    LabeledContent(
                        "Thermal BCs",
                        value: "\(model.project.thermalStudy.constraints.count)"
                    )
                    LabeledContent(
                        "Reference",
                        value: String(
                            format: "%.3g K",
                            model.project.thermalStudy.referenceTemperature
                        )
                    )
                    LabeledContent(
                        "Peak BC",
                        value: String(
                            format: "%.3g K",
                            model.project.thermalStudy.constraints
                                .map(\.temperature)
                                .max() ?? 0
                        )
                    )
                }
            }

            Section("Material") {
                LabeledContent("E (GPa)") {
                    TextField(
                        "E",
                        value: Binding(
                            get: { model.project.material.youngModulus / 1e9 },
                            set: { model.setYoungModulus($0 * 1e9) }
                        ),
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .multilineTextAlignment(.trailing)
                }
                LabeledContent("ν") {
                    TextField(
                        "ν",
                        value: Binding(
                            get: { model.project.material.poissonRatio },
                            set: { model.setPoissonRatio($0) }
                        ),
                        format: .number.precision(.fractionLength(0...3))
                    )
                    .multilineTextAlignment(.trailing)
                }
                LabeledContent("Density (kg/m³)") {
                    TextField(
                        "Density",
                        value: Binding(
                            get: { model.project.material.density },
                            set: { model.setDensity($0) }
                        ),
                        format: .number.precision(.fractionLength(0...0))
                    )
                    .multilineTextAlignment(.trailing)
                }
                LabeledContent("k (W/m·K)") {
                    TextField(
                        "Conductivity",
                        value: Binding(
                            get: { model.project.material.thermalConductivity },
                            set: { model.setThermalConductivity($0) }
                        ),
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .multilineTextAlignment(.trailing)
                }
                LabeledContent("α (1/K)") {
                    TextField(
                        "Expansion",
                        value: Binding(
                            get: { model.project.material.thermalExpansion },
                            set: { model.setThermalExpansion($0) }
                        ),
                        format: .number.precision(.fractionLength(0...8))
                    )
                    .multilineTextAlignment(.trailing)
                }
            }

            Section("Loads") {
                if model.project.analysis == .modal {
                    Text("Modal analysis ignores mechanical loads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Scale", value: String(format: "%.2f×", model.project.loadScale))
                Slider(
                    value: Binding(
                        get: { model.project.loadScale },
                        set: { model.setLoadScale($0) }
                    ),
                    in: 0...3
                )
                LabeledContent(
                    "Tip load",
                    value: String(format: "%.1f kN", tipLoadMagnitude)
                )
            }

            Section("Solver") {
                Picker(
                    "Method",
                    selection: Binding(
                        get: { model.solverPreset },
                        set: { model.setSolverPreset($0) }
                    )
                ) {
                    ForEach(SolverPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                if usesNumericCoreDirect {
                    Picker(
                        "Ordering",
                        selection: Binding(
                            get: { model.project.directSettings.ordering },
                            set: { model.setOrdering($0) }
                        )
                    ) {
                        Text("Minimum degree").tag(SparseOrderingKind.minimumDegree)
                        Text("Natural").tag(SparseOrderingKind.natural)
                    }
                    Stepper(
                        "Refinement steps: \(model.project.directSettings.refinementSteps)",
                        value: Binding(
                            get: { model.project.directSettings.refinementSteps },
                            set: { model.setRefinementSteps($0) }
                        ),
                        in: 0...10
                    )
                }
            }

            Section("Display") {
                Toggle(
                    "Stress heatmap",
                    isOn: Binding(
                        get: { model.project.showStress },
                        set: { model.setShowStress($0) }
                    )
                )
                .disabled(model.project.analysis == .modal)
                LabeledContent(
                    "Deformation",
                    value: String(format: "%.0f×", model.project.deformationScale)
                )
                Slider(
                    value: Binding(
                        get: { Double(model.project.deformationScale) },
                        set: { model.setDeformationScale(Float($0)) }
                    ),
                    in: 0...10_000
                )
            }

            Section("Results") {
                switch model.project.analysis {
                case .staticAnalysis:
                    if let result = model.result {
                        staticResultRows(result)
                    } else {
                        emptyResults
                    }
                case .modal:
                    if let modalResult = model.modalResult {
                        Picker(
                            "Mode",
                            selection: Binding(
                                get: { model.project.selectedMode },
                                set: { model.setSelectedMode($0) }
                            )
                        ) {
                            ForEach(modalResult.modes.indices, id: \.self) { index in
                                let mode = modalResult.modes[index]
                                Text(String(
                                    format: "%d · %.4g Hz",
                                    mode.index + 1,
                                    mode.frequencyHz
                                )).tag(mode.index)
                            }
                        }
                        if let mode = model.selectedMode {
                            LabeledContent(
                                "Frequency",
                                value: String(format: "%.6g Hz", mode.frequencyHz)
                            )
                            LabeledContent(
                                "Angular",
                                value: String(format: "%.6g rad/s", mode.angularFrequency)
                            )
                            LabeledContent(
                                "Mass residual",
                                value: String(format: "%.2g", mode.relativeResidual)
                            )
                        }
                        LabeledContent(
                            "Solve time",
                            value: model.lastSolveSeconds.map {
                                String(format: "%.1f ms", $0 * 1_000)
                            } ?? "—"
                        )
                    } else {
                        emptyResults
                    }
                case .thermalStructural:
                    if let thermalResult = model.thermalResult,
                       let result = model.result {
                        LabeledContent(
                            "Max temperature",
                            value: String(format: "%.4g K", thermalResult.maximumTemperature)
                        )
                        staticResultRows(result)
                    } else {
                        emptyResults
                    }
                }
            }

            if model.needsSolve {
                Section {
                    Button {
                        model.solve()
                    } label: {
                        Label("Solve Analysis", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSolving)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func staticResultRows(_ result: StaticResult) -> some View {
        LabeledContent(
            "Max displacement",
            value: String(format: "%.4g mm", result.maxDisplacement * 1_000)
        )
        LabeledContent(
            "Max von Mises",
            value: String(format: "%.4g MPa", result.maxVonMises / 1e6)
        )
        LabeledContent(
            "Strain energy",
            value: String(format: "%.4g J", result.strainEnergy)
        )
        LabeledContent(
            "Solve time",
            value: model.lastSolveSeconds.map {
                String(format: "%.1f ms", $0 * 1_000)
            } ?? "—"
        )
        LabeledContent("Solver", value: solverSummary(result.solveReport))
    }

    private var emptyResults: some View {
        Text(model.isSolving ? "Solving…" : "Run an analysis to see results.")
            .foregroundStyle(.secondary)
    }

    private var viewport: some View {
        ZStack {
            FEMViewport(
                scene: model.scene,
                options: model.renderOptions,
                onPick: { model.select($0) }
            )
            .ignoresSafeArea()

            if model.scene == nil {
                placeholder
            }

            if model.isSolving {
                ProgressView("Solving \(model.project.name)…")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    if let inspection = model.inspection {
                        inspector(inspection)
                    } else if model.scene != nil {
                        Text("Click a surface node to inspect displacement and stress.")
                            .font(.caption)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    if model.renderOptions.showStress, let scene = model.scene {
                        StressColorBar(
                            range: scene.stressRange,
                            valueScale: 1e-6,
                            unit: "MPa"
                        )
                    }
                }
                .padding()
            }

            if let error = model.errorMessage {
                VStack {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error)
                        Spacer()
                        Button {
                            model.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .padding()
                    Spacer()
                }
            }
        }
        .background(Color(white: 0.08))
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.project.name)
                .font(.title2.weight(.semibold))
            Text(placeholderDescription)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Solve Analysis") {
                model.solve()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isSolving)
        }
        .padding(30)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func inspector(_ inspection: NodeInspection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Node \(inspection.node)")
                .font(.headline)
            Text(String(
                format: "u = (%.3g, %.3g, %.3g) mm",
                inspection.displacement.x * 1_000,
                inspection.displacement.y * 1_000,
                inspection.displacement.z * 1_000
            ))
            .font(.caption.monospacedDigit())
            Text(String(
                format: "|u| = %.4g mm",
                simd_length(inspection.displacement) * 1_000
            ))
            .font(.caption.monospacedDigit())
            if let vonMises = inspection.vonMises {
                Text(String(format: "σv = %.4g MPa", vonMises / 1e6))
                    .font(.caption.monospacedDigit())
            }
            if let temperature = inspection.temperature {
                Text(String(format: "T = %.4g K", temperature))
                    .font(.caption.monospacedDigit())
            }
            if let frequency = inspection.modeFrequency {
                Text(String(format: "f = %.6g Hz", frequency))
                    .font(.caption.monospacedDigit())
            }
            Text(String(
                format: "x = (%.3g, %.3g, %.3g) m",
                inspection.position.x,
                inspection.position.y,
                inspection.position.z
            ))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var resultsCSV: String {
        model.resultsCSV
    }

    private var placeholderDescription: String {
        switch model.project.analysis {
        case .staticAnalysis:
            return "Choose a solver and run the analysis to generate the rendered stress field."
        case .modal:
            return "Run a modal analysis, then inspect the mass-normalized mode shapes."
        case .thermalStructural:
            return "Run steady conduction, then inspect the coupled thermal stress field."
        }
    }

    private var tipLoadMagnitude: Double {
        model.project.loads.reduce(0) { total, load in
            switch load {
            case .nodal(_, let vector), .traction(_, let vector):
                return total + simd_length(vector) * model.project.loadScale
            }
        }
    }

    private var usesNumericCoreDirect: Bool {
        switch model.project.solverMethod {
        case .numericCoreLU, .numericCoreLDLT:
            return true
        default:
            return false
        }
    }

    private func solverSummary(_ report: SparseSolveReport) -> String {
        var parts = [SolverPreset(method: report.method).title]
        if let iterations = report.iterations {
            parts.append("\(iterations) it")
        }
        if let residual = report.relativeResidual {
            parts.append(String(format: "r=%.2g", residual))
        }
        if let refinement = report.refinementSteps {
            parts.append("refine=\(refinement)")
        }
        return parts.joined(separator: " · ")
    }
}


private extension AnalysisKind {
    var title: String {
        switch self {
        case .staticAnalysis: return "Static"
        case .modal: return "Modal"
        case .thermalStructural: return "Thermal structural"
        }
    }
}
