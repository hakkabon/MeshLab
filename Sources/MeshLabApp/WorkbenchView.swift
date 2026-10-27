import MeshLab
import SwiftUI
import UniformTypeIdentifiers
import simd

private enum EngineeringRequirementDimension {
    case length
    case stress
    case temperature
    case scalar
}

struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchModel

    @State private var isImporting = false
    @State private var isExportingProject = false
    @State private var isExportingResults = false
    @State private var isExportingVTK = false
    @State private var didAutoSolve = false
    @State private var selectedProductionRegion = ""

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
                    Button("Export VTK…") {
                        isExportingVTK = true
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Button {
                    model.solve()
                } label: {
                    Label("Solve", systemImage: "play.fill")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isSolving || model.isDesigning)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json, .gmshMesh],
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
        .fileExporter(
            isPresented: $isExportingVTK,
            document: VTKDocument(mesh: model.displayMesh, result: model.exportResult),
            contentType: .legacyVTK,
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
                Picker("Gmsh units", selection: $model.gmshImportUnit) {
                    ForEach(MeshLengthUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue.capitalized).tag(unit)
                    }
                }
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
                    Picker("Modal solver", selection: $model.project.modalSolver) {
                        ForEach(ModalSolverKind.allCases, id: \.self) { solver in
                            Text(solver.title).tag(solver)
                        }
                    }
                }
                if model.project.analysis == .transient {
                    LabeledContent("Time step (s)") {
                        TextField(
                            "Time step",
                            value: $model.project.transientStudy.timeStep,
                            format: .number.precision(.fractionLength(1...6))
                        )
                        .multilineTextAlignment(.trailing)
                    }
                    Stepper(
                        "Steps: \(model.project.transientStudy.steps)",
                        value: $model.project.transientStudy.steps,
                        in: 1...10_000
                    )
                    LabeledContent("Duration", value: String(
                        format: "%.4g s",
                        model.project.transientStudy.timeStep
                            * Double(model.project.transientStudy.steps)
                    ))
                }
                if model.project.analysis == .productionLinear {
                    LabeledContent(
                        "Load cases",
                        value: "\(model.project.linearStudy.loadCases.count)"
                    )
                    LabeledContent(
                        "Combinations",
                        value: "\(model.project.linearStudy.combinations.count)"
                    )
                    LabeledContent(
                        "Region constraints",
                        value: "\(model.project.linearStudy.regionConstraints.count)"
                    )
                    LabeledContent(
                        "Material regions",
                        value: "\(model.project.linearStudy.materialAssignments.count)"
                    )
                }
                if model.project.analysis == .nonlinearStatic {
                    LabeledContent(
                        "Load steps",
                        value: "\(model.project.nonlinearOptions.loadSteps)"
                    )
                    LabeledContent(
                        "Newton limit",
                        value: "\(model.project.nonlinearOptions.maximumNewtonIterations)"
                    )
                }
                if model.project.analysis == .coupledThermoMechanical {
                    LabeledContent(
                        "Coupling limit",
                        value: "\(model.project.coupledOptions.maximumIterations)"
                    )
                    LabeledContent(
                        "Relaxation",
                        value: String(format: "%.3g", model.project.coupledOptions.relaxation)
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

            Section("Design Study") {
                Picker(
                    "Study",
                    selection: Binding(
                        get: { model.project.designStudy.kind },
                        set: { model.setDesignKind($0) }
                    )
                ) {
                    ForEach(DesignStudyKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }

                switch model.project.designStudy.kind {
                case .parametric:
                    let study = model.project.designStudy.parametric
                    if study.axes.isEmpty {
                        Text("A default Young's modulus and load sweep is created when the study runs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(study.axes.enumerated()), id: \.offset) { _, axis in
                            LabeledContent(axis.parameter.title) {
                                Text(axis.values.map {
                                    formatDesignValue($0, parameter: axis.parameter)
                                }.joined(separator: ", "))
                                .font(.caption.monospacedDigit())
                                .multilineTextAlignment(.trailing)
                            }
                        }
                        LabeledContent(
                            "Samples",
                            value: "\(parametricSampleCount)"
                        )
                    }
                    LabeledContent("Objective", value: study.objective.title)
                    LabeledContent(
                        "Constraints",
                        value: "\(study.constraints.count)"
                    )
                    LabeledContent(
                        "Pareto metrics",
                        value: study.paretoObjectives.map(\.title).joined(separator: ", ")
                    )

                case .topology:
                    LabeledContent(
                        "Volume target",
                        value: String(
                            format: "%.0f%%",
                            model.project.designStudy.topology.volumeFraction * 100
                        )
                    )
                    Slider(
                        value: Binding(
                            get: {
                                model.project.designStudy.topology.volumeFraction
                            },
                            set: { model.setTopologyVolumeFraction($0) }
                        ),
                        in: 0.1...0.9
                    )
                    Stepper(
                        "Outer iterations: \(model.project.designStudy.topology.outerIterations)",
                        value: Binding(
                            get: {
                                model.project.designStudy.topology.outerIterations
                            },
                            set: { model.setTopologyOuterIterations($0) }
                        ),
                        in: 1...12
                    )
                    Stepper(
                        "Inner iterations: \(model.project.designStudy.topology.innerIterations)",
                        value: Binding(
                            get: {
                                model.project.designStudy.topology.innerIterations
                            },
                            set: { model.setTopologyInnerIterations($0) }
                        ),
                        in: 1...100
                    )

                case .shape:
                    Picker(
                        "Selected face",
                        selection: Binding(
                            get: {
                                model.project.designStudy.shape.selectionAxis
                            },
                            set: { model.setShapeSelectionAxis($0) }
                        )
                    ) {
                        ForEach(0..<model.project.mesh.dimension, id: \.self) { axis in
                            Text(axisName(axis)).tag(axis)
                        }
                    }
                    Picker(
                        "Motion axis",
                        selection: Binding(
                            get: {
                                model.project.designStudy.shape.motionAxis
                            },
                            set: { model.setShapeMotionAxis($0) }
                        )
                    ) {
                        ForEach(0..<model.project.mesh.dimension, id: \.self) { axis in
                            Text(axisName(axis)).tag(axis)
                        }
                    }
                    LabeledContent(
                        "Margin",
                        value: String(
                            format: "±%.3g m",
                            model.project.designStudy.shape.margin
                        )
                    )
                    Slider(
                        value: Binding(
                            get: { model.project.designStudy.shape.margin },
                            set: { model.setShapeMargin($0) }
                        ),
                        in: 0.01...0.5
                    )
                    Stepper(
                        "Outer iterations: \(model.project.designStudy.shape.outerIterations)",
                        value: Binding(
                            get: {
                                model.project.designStudy.shape.outerIterations
                            },
                            set: { model.setShapeOuterIterations($0) }
                        ),
                        in: 1...12
                    )
                    Stepper(
                        "Inner iterations: \(model.project.designStudy.shape.innerIterations)",
                        value: Binding(
                            get: {
                                model.project.designStudy.shape.innerIterations
                            },
                            set: { model.setShapeInnerIterations($0) }
                        ),
                        in: 1...100
                    )
                }

                Button {
                    model.runDesign()
                } label: {
                    Label("Run Design Study", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSolving || model.isDesigning)

                if model.isDesigning {
                    HStack {
                        ProgressView()
                        Text("Optimizing…")
                    }
                }

                if let designResult = model.designResult {
                    designResultRows(designResult)
                }
            }

            if model.project.analysis == .productionLinear {
                Section("Production Study Authoring") {
                    if productionRegionNames.isEmpty {
                        Text("Import a Gmsh mesh with named physical regions to author region-based studies.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Region", selection: $selectedProductionRegion) {
                            Text("Select region").tag("")
                            ForEach(productionRegionNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        Button("Add Fixed Region") {
                            model.addProductionConstraint(regionName: productionRegion)
                        }
                        .disabled(productionRegion.isEmpty)
                        Button("Add Region Load Case") {
                            model.addProductionLoadCase(regionName: productionRegion)
                        }
                        .disabled(productionRegion.isEmpty)
                    }
                    ForEach(
                        Array(model.project.linearStudy.regionConstraints.enumerated()),
                        id: \.offset
                    ) { index, constraint in
                        HStack {
                            Text("Fixed: \(constraint.regionName)")
                            Spacer()
                            Button(role: .destructive) {
                                model.removeProductionConstraint(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    ForEach(
                        Array(model.project.linearStudy.loadCases.enumerated()),
                        id: \.offset
                    ) { index, loadCase in
                        HStack {
                            Text("\(loadCase.id): \(loadCase.name)")
                            Spacer()
                            Button(role: .destructive) {
                                model.removeProductionLoadCase(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add 1.0× Combination") {
                        model.addProductionCombination()
                    }
                    .disabled(model.project.linearStudy.loadCases.isEmpty)
                    ForEach(
                        Array(model.project.linearStudy.combinations.enumerated()),
                        id: \.offset
                    ) { index, combination in
                        HStack {
                            Text("\(combination.id): \(combination.terms.count) terms")
                            Spacer()
                            Button(role: .destructive) {
                                model.removeProductionCombination(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("Engineering Qualification") {
                TextField(
                    "Project ID",
                    text: $model.project.engineeringMetadata.identifier
                )
                TextField(
                    "Revision",
                    text: $model.project.engineeringMetadata.revision
                )
                TextField(
                    "Analyst",
                    text: $model.project.engineeringMetadata.analyst
                )
                TextField(
                    "Summary",
                    text: $model.project.engineeringMetadata.summary,
                    axis: .vertical
                )
                let requirements = model.project.engineeringRequirements
                LabeledContent(
                    "Configured limits",
                    value: "\(engineeringRequirementCount(requirements))"
                )
                DisclosureGroup("Acceptance limits") {
                    Picker("Length", selection: $model.project.engineeringUnits.length) {
                        ForEach(EngineeringLengthUnit.allCases, id: \.self) {
                            Text($0.symbol).tag($0)
                        }
                    }
                    Picker("Stress", selection: $model.project.engineeringUnits.stress) {
                        ForEach(EngineeringStressUnit.allCases, id: \.self) {
                            Text($0.symbol).tag($0)
                        }
                    }
                    Picker("Temperature", selection: $model.project.engineeringUnits.temperature) {
                        ForEach(EngineeringTemperatureUnit.allCases, id: \.self) {
                            Text($0.symbol).tag($0)
                        }
                    }
                    Toggle(
                        "Require convergence",
                        isOn: $model.project.engineeringRequirements.requireConvergence
                    )
                    TextField(
                        "Max displacement (\(model.project.engineeringUnits.length.symbol))",
                        text: engineeringRequirementBinding(\.maximumDisplacement, dimension: .length)
                    )
                    TextField(
                        "Max von Mises (\(model.project.engineeringUnits.stress.symbol))",
                        text: engineeringRequirementBinding(\.maximumVonMises, dimension: .stress)
                    )
                    TextField(
                        "Max temperature (\(model.project.engineeringUnits.temperature.symbol))",
                        text: engineeringRequirementBinding(\.maximumTemperature, dimension: .temperature)
                    )
                    TextField(
                        "Min frequency",
                        text: engineeringRequirementBinding(\.minimumFrequency, dimension: .scalar)
                    )
                    TextField(
                        "Max relative residual",
                        text: engineeringRequirementBinding(\.maximumRelativeResidual, dimension: .scalar)
                    )
                    TextField(
                        "Min mesh quality",
                        text: engineeringRequirementBinding(\.minimumMeshQuality, dimension: .scalar)
                    )
                }
                Button {
                    model.runEngineeringAssessment()
                } label: {
                    Label("Run Qualification", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isAssessing || model.isSolving || model.isDesigning)

                if model.isAssessing {
                    ProgressView("Assessing…")
                }
                if let artifact = model.engineeringArtifact {
                    LabeledContent(
                        "Status",
                        value: artifact.passed ? "PASS" : "FAIL"
                    )
                    LabeledContent(
                        "Fingerprint",
                        value: artifact.projectFingerprint
                    )
                    ForEach(Array(artifact.checks.enumerated()), id: \.offset) { _, check in
                        LabeledContent(
                            check.kind.rawValue,
                            value: check.status.rawValue
                        )
                    }
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
                if ![.modal, .transient].contains(model.project.analysis) {
                    Toggle(
                        "Matrix-free CG",
                        isOn: Binding(
                            get: { model.project.useMatrixFree },
                            set: { model.setUseMatrixFree($0) }
                        )
                    )
                    if model.project.useMatrixFree {
                        Stepper(
                            "CG iterations: \(model.project.matrixFreeOptions.maximumIterations)",
                            value: Binding(
                                get: {
                                    model.project.matrixFreeOptions.maximumIterations
                                },
                                set: { model.setMatrixFreeIterations($0) }
                            ),
                            in: 1...20_000
                        )
                        Text("Uses element-by-element stiffness products and Jacobi-preconditioned conjugate gradients.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if usesNumericCoreDirect, !model.project.useMatrixFree {
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
                .disabled([.modal, .transient].contains(model.project.analysis))
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
                case .productionLinear:
                    if let linear = model.linearResult,
                       let result = model.result {
                        Picker(
                            "Result",
                            selection: Binding(
                                get: {
                                    model.project.selectedLinearResultID
                                        ?? linear.results.first?.id
                                        ?? ""
                                },
                                set: { model.setSelectedLinearResult($0) }
                            )
                        ) {
                            ForEach(linear.results, id: \.id) { value in
                                Text(value.name).tag(value.id)
                            }
                        }
                        LabeledContent(
                            "Envelope displacement",
                            value: String(
                                format: "%.4g mm",
                                linear.envelope.maximumDisplacement * 1_000
                            )
                        )
                        if let identifier = linear.envelope.maximumDisplacementResultID {
                            LabeledContent("Displacement governs", value: identifier)
                        }
                        LabeledContent(
                            "Envelope stress",
                            value: String(
                                format: "%.4g MPa",
                                linear.envelope.maximumVonMises / 1e6
                            )
                        )
                        if let identifier = linear.envelope.maximumVonMisesResultID {
                            LabeledContent("Stress governs", value: identifier)
                        }
                        staticResultRows(result)
                    } else {
                        emptyResults
                    }
                case .nonlinearStatic:
                    if let nonlinear = model.nonlinearResult,
                       let result = model.result {
                        LabeledContent(
                            "Load steps",
                            value: "\(nonlinear.loadSteps.count)"
                        )
                        LabeledContent(
                            "Newton iterations",
                            value: "\(nonlinear.totalNewtonIterations)"
                        )
                        staticResultRows(result)
                    } else {
                        emptyResults
                    }
                case .coupledThermoMechanical:
                    if let coupled = model.coupledResult,
                       let result = model.result {
                        LabeledContent(
                            "Coupling",
                            value: coupled.converged ? "Converged" : "Iteration limit"
                        )
                        LabeledContent(
                            "Coupling iterations",
                            value: "\(coupled.iterations.count)"
                        )
                        LabeledContent(
                            "Max temperature",
                            value: String(
                                format: "%.4g K",
                                coupled.thermalResult.maximumTemperature
                            )
                        )
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
                case .transient:
                    if let transient = model.transientResult,
                       let state = model.selectedTransientState {
                        Slider(
                            value: Binding(
                                get: { Double(model.selectedTransientStep) },
                                set: { model.setSelectedTransientStep(Int($0.rounded())) }
                            ),
                            in: 0...Double(max(transient.states.count - 1, 0)),
                            step: 1
                        )
                        LabeledContent(
                            "Step",
                            value: "\(model.selectedTransientStep) / \(transient.states.count - 1)"
                        )
                        LabeledContent(
                            "Time",
                            value: String(format: "%.6g s", state.time)
                        )
                        LabeledContent(
                            "Peak displacement",
                            value: String(
                                format: "%.4g mm",
                                state.displacement.reduce(0.0) {
                                    max($0, simd_length($1))
                                } * 1_000
                            )
                        )
                        LabeledContent(
                            "Kinetic energy",
                            value: String(format: "%.6g J", state.kineticEnergy)
                        )
                        LabeledContent(
                            "Strain energy",
                            value: String(format: "%.6g J", state.strainEnergy)
                        )
                        LabeledContent(
                            "Max equilibrium residual",
                            value: String(
                                format: "%.3g",
                                transient.maximumRelativeEquilibriumResidual
                            )
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
    private func designResultRows(_ outcome: DesignRunResult) -> some View {
        switch outcome {
        case .parametric(let result):
            LabeledContent(
                "Best sample",
                value: "#\(result.bestIndex + 1) of \(result.samples.count)"
            )
            LabeledContent("Objective", value: result.objective.title)
            LabeledContent(
                "Feasible samples",
                value: "\(result.feasibleSampleCount) of \(result.samples.count)"
            )
            LabeledContent("Pareto samples", value: "\(result.paretoIndices.count)")
            if let best = result.best {
                ForEach(Array(result.axes.enumerated()), id: \.offset) { index, axis in
                    if best.values.indices.contains(index) {
                        LabeledContent(
                            axis.parameter.title,
                            value: formatDesignValue(
                                best.values[index],
                                parameter: axis.parameter
                            )
                        )
                    }
                }
                LabeledContent(
                    "Best compliance",
                    value: String(format: "%.4g J", best.compliance)
                )
                LabeledContent(
                    "Peak displacement",
                    value: String(format: "%.4g mm", best.maxDisplacement * 1_000)
                )
                LabeledContent(
                    "Peak von Mises",
                    value: String(format: "%.4g MPa", best.maxVonMises / 1e6)
                )
            }
            designTimeRow

        case .topology(let result):
            LabeledContent(
                "Final compliance",
                value: String(format: "%.4g J", result.finalCompliance)
            )
            LabeledContent(
                "Compliance change",
                value: complianceChange(
                    initial: result.initialCompliance,
                    final: result.finalCompliance
                )
            )
            LabeledContent(
                "Volume",
                value: String(format: "%.1f%%", result.volumeFraction * 100)
            )
            LabeledContent("Outer iterations", value: "\(result.iterations.count)")
            LabeledContent(
                "Last inner iterations",
                value: "\(result.optimization.iterations)"
            )
            designTimeRow

        case .shape(let result):
            LabeledContent(
                "Final compliance",
                value: String(format: "%.4g J", result.finalCompliance)
            )
            LabeledContent(
                "Compliance change",
                value: complianceChange(
                    initial: result.initialCompliance,
                    final: result.finalCompliance
                )
            )
            LabeledContent(
                "Volume",
                value: String(format: "%.1f%%", result.volumeFraction * 100)
            )
            LabeledContent("Variables", value: "\(result.variables.count)")
            LabeledContent("Outer iterations", value: "\(result.iterations.count)")
            LabeledContent(
                "Last inner iterations",
                value: "\(result.optimization.iterations)"
            )
            designTimeRow
        }
    }

    private var designTimeRow: some View {
        LabeledContent(
            "Design time",
            value: model.lastDesignSeconds.map {
                String(format: "%.2f s", $0)
            } ?? "—"
        )
    }

    private func complianceChange(initial: Double, final: Double) -> String {
        guard initial > 0 else { return "—" }
        return String(format: "%+.1f%%", (final / initial - 1) * 100)
    }

    private func formatDesignValue(
        _ value: Double,
        parameter: DesignParameter
    ) -> String {
        switch parameter {
        case .youngModulus:
            return String(format: "%.4g GPa", value / 1e9)
        case .poissonRatio:
            return String(format: "%.4g", value)
        case .thickness:
            return String(format: "%.4g m", value)
        case .loadScale:
            return String(format: "%.4g×", value)
        }
    }

    private func engineeringRequirementCount(_ value: EngineeringRequirements) -> Int {
        [
            value.maximumDisplacement,
            value.maximumVonMises,
            value.maximumTemperature,
            value.minimumFrequency,
            value.maximumRelativeResidual,
            value.minimumMeshQuality,
        ].compactMap { $0 }.count + (value.requireConvergence ? 1 : 0)
    }

    private func engineeringRequirementBinding(
        _ keyPath: WritableKeyPath<EngineeringRequirements, Double?>,
        dimension: EngineeringRequirementDimension
    ) -> Binding<String> {
        Binding(
            get: {
                model.project.engineeringRequirements[keyPath: keyPath].map {
                    String(format: "%.8g", displayRequirement($0, dimension: dimension))
                } ?? ""
            },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                var requirements = model.project.engineeringRequirements
                if trimmed.isEmpty {
                    requirements[keyPath: keyPath] = nil
                } else if let value = Double(trimmed), value.isFinite {
                    requirements[keyPath: keyPath] = solverRequirement(
                        value,
                        dimension: dimension
                    )
                } else {
                    return
                }
                model.project.engineeringRequirements = requirements
            }
        )
    }

    private func displayRequirement(
        _ value: Double,
        dimension: EngineeringRequirementDimension
    ) -> Double {
        switch dimension {
        case .length:
            model.project.engineeringUnits.length.displayValue(fromSolver: value)
        case .stress:
            model.project.engineeringUnits.stress.displayValue(fromSolver: value)
        case .temperature:
            model.project.engineeringUnits.temperature.displayValue(fromSolver: value)
        case .scalar:
            value
        }
    }

    private func solverRequirement(
        _ value: Double,
        dimension: EngineeringRequirementDimension
    ) -> Double {
        switch dimension {
        case .length:
            model.project.engineeringUnits.length.solverValue(fromDisplay: value)
        case .stress:
            model.project.engineeringUnits.stress.solverValue(fromDisplay: value)
        case .temperature:
            model.project.engineeringUnits.temperature.solverValue(fromDisplay: value)
        case .scalar:
            value
        }
    }

    private var productionRegionNames: [String] {
        Array(Set(model.project.meshMetadata.regions
            .filter { !$0.nodeIndices.isEmpty }
            .map(\.name)))
            .sorted()
    }

    private var productionRegion: String {
        productionRegionNames.contains(selectedProductionRegion)
            ? selectedProductionRegion
            : ""
    }

    private var parametricSampleCount: Int {
        model.project.designStudy.parametric.axes.reduce(1) {
            $0 * max($1.values.count, 1)
        }
    }

    private func axisName(_ axis: Int) -> String {
        switch axis {
        case 0: return "X"
        case 1: return "Y"
        default: return "Z"
        }
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
            "Force imbalance",
            value: String(
                format: "%.3g N",
                simd_length(result.equilibrium.forceImbalance)
            )
        )
        LabeledContent(
            "Moment imbalance",
            value: String(
                format: "%.3g N·m",
                simd_length(result.equilibrium.momentImbalance)
            )
        )
        LabeledContent(
            "Free residual",
            value: String(format: "%.3g", result.equilibrium.relativeFreeResidual)
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
            } else if model.isDesigning {
                ProgressView("Optimizing \(model.project.name)…")
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
            .disabled(model.isSolving || model.isDesigning)
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
        case .productionLinear:
            return "Run the configured load cases and combinations, then inspect individual or envelope results."
        case .nonlinearStatic:
            return "Run incremental finite-strain equilibrium with damped Newton iterations."
        case .coupledThermoMechanical:
            return "Run staggered thermal and structural fields until their updates converge."
        case .modal:
            return "Run a modal analysis, then inspect the mass-normalized mode shapes."
        case .transient:
            return "Run transient dynamics, then scrub the displacement history through time."
        case .thermalStructural:
            return "Run steady conduction, then inspect the coupled thermal stress field."
        }
    }

    private var tipLoadMagnitude: Double {
        model.project.loads.reduce(0) { total, load in
            switch load {
            case .nodal(_, let vector), .traction(_, let vector):
                return total + simd_length(vector) * model.project.loadScale
            case .pressure(_, let magnitude):
                return total + abs(magnitude) * model.project.loadScale
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
        var parts = [
            model.project.useMatrixFree
                ? "Matrix-free CG"
                : SolverPreset(method: report.method).title,
        ]
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


private extension DesignStudyKind {
    var title: String {
        switch self {
        case .parametric: return "Parametric sweep"
        case .topology: return "Topology optimization"
        case .shape: return "Shape optimization"
        }
    }
}

private extension DesignParameter {
    var title: String {
        switch self {
        case .youngModulus: return "Young's modulus"
        case .poissonRatio: return "Poisson ratio"
        case .thickness: return "Thickness"
        case .loadScale: return "Load scale"
        }
    }
}

private extension ParametricObjective {
    var title: String {
        switch self {
        case .compliance: return "Minimize compliance"
        case .maxDisplacement: return "Minimize displacement"
        case .maxVonMises: return "Minimize stress"
        }
    }
}

private extension AnalysisKind {
    var title: String {
        switch self {
        case .staticAnalysis: return "Static"
        case .productionLinear: return "Production linear"
        case .nonlinearStatic: return "Nonlinear static"
        case .coupledThermoMechanical: return "Coupled thermo-mechanical"
        case .modal: return "Modal"
        case .transient: return "Transient dynamics"
        case .thermalStructural: return "Thermal structural"
        }
    }
}

private extension ModalSolverKind {
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .dense: return "Dense LAPACK"
        case .sparseSubspace: return "Sparse subspace"
        }
    }
}
