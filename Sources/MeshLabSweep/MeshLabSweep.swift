import Foundation
import MeshLabCore

@main
struct MeshLabSweepCommand {
    static func main() async {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            let input: Data
            if arguments.input == "-" {
                input = FileHandle.standardInput.readDataToEndOfFile()
            } else {
                input = try Data(contentsOf: URL(fileURLWithPath: arguments.input))
            }
            let job = try SweepJobFile.decode(input)
            let result = await SweepRunner.run(
                job,
                maxConcurrency: arguments.concurrency
            )
            let data = try SweepJobFile.encode(result)
            if let output = arguments.output {
                try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            let failed = result.summaries.filter { $0.status == .failed }.count
            if failed > 0 {
                FileHandle.standardError.write(Data(
                    "\(failed) sweep request(s) failed\n".utf8
                ))
                exit(1)
            }
        } catch CLIError.usage {
            print(CLIError.usage.description)
        } catch {
            FileHandle.standardError.write(Data("'\(error)'\n".utf8))
            exit(1)
        }
    }

    private struct Arguments {
        var input: String
        var output: String?
        var concurrency: Int

        init(_ values: [String]) throws {
            var input: String?
            var output: String?
            var concurrency = max(1, ProcessInfo.processInfo.activeProcessorCount)
            var iterator = values.makeIterator()
            while let value = iterator.next() {
                switch value {
                case "--output", "-o":
                    guard let value = iterator.next() else {
                        throw CLIError.invalidArguments(
                            "--output needs a file path"
                        )
                    }
                    output = value
                case "--concurrency", "-j":
                    guard let raw = iterator.next(), let parsed = Int(raw),
                          parsed > 0 else {
                        throw CLIError.invalidArguments(
                            "--concurrency needs a positive integer"
                        )
                    }
                    concurrency = parsed
                case "--help", "-h":
                    throw CLIError.usage
                default:
                    guard input == nil else {
                        throw CLIError.invalidArguments(
                            "Only one input file may be provided"
                        )
                    }
                    input = value
                }
            }
            guard let input else { throw CLIError.usage }
            self.input = input
            self.output = output
            self.concurrency = concurrency
        }
    }

    private enum CLIError: Error, CustomStringConvertible {
        case usage
        case invalidArguments(String)

        var description: String {
            switch self {
            case .usage:
                return """
                Usage: MeshLabSweep <job.json|-> [--output result.json] [--concurrency N]
                """
            case .invalidArguments(let message):
                return message
            }
        }
    }
}
