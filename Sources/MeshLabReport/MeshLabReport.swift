import Foundation
import MeshLabCore

@main
struct MeshLabReportCommand {
    static func main() {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            let input: Data
            if arguments.input == "-" {
                input = FileHandle.standardInput.readDataToEndOfFile()
            } else {
                input = try Data(contentsOf: URL(fileURLWithPath: arguments.input))
            }
            let project = try MeshLabProjectFile.decode(input)
            let artifact = try EngineeringAssessment.run(project)
            let json = try artifact.jsonData()
            if let output = arguments.output {
                try json.write(to: URL(fileURLWithPath: output), options: .atomic)
            } else {
                FileHandle.standardOutput.write(json)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            if let markdown = arguments.markdown {
                try artifact.markdown().write(
                    to: URL(fileURLWithPath: markdown),
                    atomically: true,
                    encoding: .utf8
                )
            }
            if !artifact.passed { exit(2) }
        } catch CLIError.usage {
            print(CLIError.usage.description)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private struct Arguments {
        let input: String
        let output: String?
        let markdown: String?

        init(_ values: [String]) throws {
            var input: String?
            var output: String?
            var markdown: String?
            var iterator = values.makeIterator()
            while let value = iterator.next() {
                switch value {
                case "--output", "-o":
                    guard let path = iterator.next() else {
                        throw CLIError.invalidArguments("--output needs a file path")
                    }
                    output = path
                case "--markdown":
                    guard let path = iterator.next() else {
                        throw CLIError.invalidArguments("--markdown needs a file path")
                    }
                    markdown = path
                case "--help", "-h":
                    throw CLIError.usage
                default:
                    guard input == nil else {
                        throw CLIError.invalidArguments("Only one project may be assessed")
                    }
                    input = value
                }
            }
            guard let input else { throw CLIError.usage }
            self.input = input
            self.output = output
            self.markdown = markdown
        }
    }

    private enum CLIError: Error, CustomStringConvertible {
        case usage
        case invalidArguments(String)

        var description: String {
            switch self {
            case .usage:
                return """
                Usage: MeshLabReport <project.json|-> [--output artifact.json]
                                     [--markdown report.md]
                Exit status 0 means all engineering checks passed; 2 means the
                analysis completed but one or more checks did not pass.
                """
            case .invalidArguments(let message):
                return message
            }
        }
    }
}
