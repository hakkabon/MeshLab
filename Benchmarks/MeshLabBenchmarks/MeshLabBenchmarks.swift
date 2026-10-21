import Foundation
import MeshLabCore
import MeshLabRender
import simd

@main
struct MeshLabBenchmarks {
    struct Configuration {
        var divisions = SIMD3<Int>(4, 4, 16)
        var iterations = 5
        var json = false
        var quick = false
    }

    struct Fixture {
        let mesh: Mesh
        let model: FEMModel
        let surface: SurfaceMesh
        let result: StaticResult
        let scene: RenderScene
    }

    struct Measurement: Codable {
        let name: String
        let iterations: Int
        let minMilliseconds: Double
        let medianMilliseconds: Double
        let maxMilliseconds: Double
    }

    struct Report: Codable {
        let schemaVersion: Int
        let generatedAt: String
        let platform: String
        let architecture: String
        let buildConfiguration: String
        let solver: String
        let divisions: [Int]
        let nodeCount: Int
        let elementCount: Int
        let dofCount: Int
        let surfaceTriangleCount: Int
        let measurements: [Measurement]
    }

    enum BenchmarkError: Error, CustomStringConvertible {
        case invalidArgument(String)
        case invalidValue(String, String)
        case noIterations

        var description: String {
            switch self {
            case .invalidArgument(let argument):
                return "Unknown argument: \(argument)"
            case .invalidValue(let option, let value):
                return "Invalid value for \(option): \(value)"
            case .noIterations:
                return "Iterations must be greater than zero"
            }
        }
    }

    static func main() {
        do {
            let configuration = try parse(CommandLine.arguments)
            try run(configuration)
        } catch {
            writeError("\(error)\n\n")
            printUsage()
            exit(2)
        }
    }

    private static func run(_ configuration: Configuration) throws {
        let fixture = try makeFixture(configuration)
        let warmup = configuration.quick ? 0 : 1

        let meshMeasurement = try measure(
            name: "mesh.generation",
            iterations: configuration.iterations,
            warmup: warmup
        ) {
            let mesh = try MeshGenerators.structuredBox(
                size: SIMD3<Double>(1, 1, 4),
                divisions: configuration.divisions
            )
            return Double(mesh.nodes.count + mesh.elements.count)
        }

        let surfaceMeasurement = try measure(
            name: "surface.extraction",
            iterations: configuration.iterations,
            warmup: warmup
        ) {
            let surface = try fixture.mesh.makeSurfaceMesh()
            return Double(surface.indices.count)
        }

        let solveMeasurement = try measure(
            name: "assembly.solve",
            iterations: configuration.iterations,
            warmup: warmup
        ) {
            let result = try StaticAnalysis().solve(fixture.model)
            return result.maxDisplacement
        }

        let matrixFreeMeasurement = try measure(
            name: "matrixfree.solve",
            iterations: configuration.iterations,
            warmup: warmup
        ) {
            let result = try StaticAnalysis(options: AnalysisOptions(
                matrixFreeOptions: MatrixFreeOptions()
            )).solve(fixture.model)
            return result.maxDisplacement
        }

        let sceneMeasurement = measure(
            name: "render.scene",
            iterations: configuration.iterations,
            warmup: warmup
        ) {
            let scene = RenderScene(surface: fixture.surface, result: fixture.result)
            return Double(scene.stressRange.upperBound)
        }

        let endToEndMeasurement = try measure(
            name: "end-to-end",
            iterations: max(1, configuration.iterations / 2),
            warmup: warmup
        ) {
            let pipeline = try runPipeline(configuration)
            return pipeline.result.maxDisplacement + Double(pipeline.scene.stress.count)
        }

        let measurements = [
            meshMeasurement,
            surfaceMeasurement,
            solveMeasurement,
            matrixFreeMeasurement,
            sceneMeasurement,
            endToEndMeasurement,
        ]

        let report = Report(
            schemaVersion: 1,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            platform: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architectureName,
            buildConfiguration: buildConfigurationName,
            solver: "automatic + matrix-free CG",
            divisions: [
                configuration.divisions.x,
                configuration.divisions.y,
                configuration.divisions.z,
            ],
            nodeCount: fixture.mesh.nodes.count,
            elementCount: fixture.mesh.elements.count,
            dofCount: fixture.mesh.dofCount,
            surfaceTriangleCount: fixture.surface.triangleCount,
            measurements: measurements
        )

        if configuration.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            printTable(report)
        }
    }

    private static func makeFixture(_ configuration: Configuration) throws -> Fixture {
        let mesh = try MeshGenerators.structuredBox(
            size: SIMD3<Double>(1, 1, 4),
            divisions: configuration.divisions
        )
        let material = try ElasticMaterial(
            youngModulus: 200e9,
            poissonRatio: 0.3,
            density: 7800
        )
        let constraints = mesh.nodeIndices { abs($0.z) < 1e-12 }
            .map { DirichletCondition.fixed(node: $0) }
        let loadedNodes = mesh.nodeIndices { abs($0.z - 4) < 1e-9 }
        let loads = loadedNodes.map {
            Load.nodal(node: $0, vector: SIMD3<Double>(0, 0, -100))
        }
        let model = FEMModel(
            mesh: mesh,
            material: material,
            constraints: constraints,
            loads: loads
        )
        let surface = try mesh.makeSurfaceMesh()
        let result = try StaticAnalysis().solve(model)
        let scene = RenderScene(surface: surface, result: result)
        return Fixture(
            mesh: mesh,
            model: model,
            surface: surface,
            result: result,
            scene: scene
        )
    }

    private static func runPipeline(
        _ configuration: Configuration
    ) throws -> (result: StaticResult, scene: RenderScene) {
        let fixture = try makeFixture(configuration)
        return (fixture.result, fixture.scene)
    }

    private static func measure(
        name: String,
        iterations: Int,
        warmup: Int,
        _ body: () throws -> Double
    ) rethrows -> Measurement {
        precondition(iterations > 0, "Benchmark iterations must be positive")
        var checksum = 0.0
        for _ in 0..<warmup {
            checksum += try body()
        }

        var samples = [Double]()
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            checksum += try body()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1_000_000)
        }
        withExtendedLifetime(checksum) {}

        let sorted = samples.sorted()
        let median: Double
        if sorted.count.isMultiple(of: 2) {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        } else {
            median = sorted[sorted.count / 2]
        }
        return Measurement(
            name: name,
            iterations: iterations,
            minMilliseconds: sorted.first ?? 0,
            medianMilliseconds: median,
            maxMilliseconds: sorted.last ?? 0
        )
    }

    private static func printTable(_ report: Report) {
        print("MeshLab benchmark")
        print("  platform:   \(report.platform)")
        print("  arch:       \(report.architecture) (\(report.buildConfiguration))")
        print("  divisions:  \(report.divisions.map(String.init).joined(separator: "x"))")
        print("  nodes:      \(report.nodeCount)")
        print("  elements:   \(report.elementCount)")
        print("  DOFs:       \(report.dofCount)")
        print("  triangles:  \(report.surfaceTriangleCount)")
        print("  solver:     \(report.solver)")
        print("")
        print(
            column("benchmark", 20)
                + column("iters", 9, right: true)
                + column("median ms", 13, right: true)
                + column("min ms", 13, right: true)
                + column("max ms", 13, right: true)
        )
        for measurement in report.measurements {
            print(
                column(measurement.name, 20)
                    + column(String(measurement.iterations), 9, right: true)
                    + column(String(format: "%.3f", measurement.medianMilliseconds), 13, right: true)
                    + column(String(format: "%.3f", measurement.minMilliseconds), 13, right: true)
                    + column(String(format: "%.3f", measurement.maxMilliseconds), 13, right: true)
            )
        }
    }

    private static func column(_ text: String, _ width: Int, right: Bool = false) -> String {
        guard text.count < width else { return text }
        let padding = String(repeating: " ", count: width - text.count)
        return right ? padding + text : text + padding
    }

    private static func parse(_ arguments: [String]) throws -> Configuration {
        var configuration = Configuration()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                configuration.json = true
            case "--quick":
                configuration.quick = true
                configuration.divisions = SIMD3<Int>(3, 3, 8)
                configuration.iterations = 1
            case "--iterations":
                index += 1
                guard index < arguments.count else {
                    throw BenchmarkError.invalidArgument("--iterations requires a value")
                }
                guard let value = Int(arguments[index]), value > 0 else {
                    throw BenchmarkError.invalidValue("--iterations", arguments[index])
                }
                configuration.iterations = value
            case "--divisions":
                index += 1
                guard index < arguments.count else {
                    throw BenchmarkError.invalidArgument("--divisions requires X,Y,Z")
                }
                let components = arguments[index]
                    .split(separator: ",")
                    .compactMap { Int($0) }
                guard components.count == 3, components.allSatisfy({ $0 > 0 }) else {
                    throw BenchmarkError.invalidValue("--divisions", arguments[index])
                }
                configuration.divisions = SIMD3<Int>(
                    components[0],
                    components[1],
                    components[2]
                )
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                throw BenchmarkError.invalidArgument(argument)
            }
            index += 1
        }
        guard configuration.iterations > 0 else {
            throw BenchmarkError.noIterations
        }
        return configuration
    }

    private static func printUsage() {
        print("""
        Usage: MeshLabBenchmarks [options]

        Options:
          --quick              Small mesh, one iteration
          --iterations N       Iterations per benchmark (default: 5)
          --divisions X,Y,Z    Structured box divisions (default: 4,4,16)
          --json               Emit a JSON report
          --help, -h           Show this help
        """)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    private static var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static var buildConfigurationName: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }
}
