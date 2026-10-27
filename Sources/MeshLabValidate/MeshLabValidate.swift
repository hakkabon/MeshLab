import Darwin
import Foundation
import MeshLabCore

@main
enum MeshLabValidateCommand {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print("Usage: MeshLabValidate [--baseline report.json] [--write report.json]")
            return
        }
        let report = try MeshLabValidation.runStandardSuite()
        let data = try report.jsonData(prettyPrinted: true)
        if let output = value(after: "--write", in: arguments) {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        var passed = report.passed
        if let path = value(after: "--baseline", in: arguments) {
            let baseline = try JSONDecoder().decode(
                ValidationReport.self,
                from: Data(contentsOf: URL(fileURLWithPath: path))
            )
            let comparison = report.compare(to: baseline)
            for issue in comparison.issues {
                FileHandle.standardError.write(
                    Data("baseline: \(issue.path): \(issue.message)\n".utf8)
                )
            }
            passed = passed && comparison.passed
        }
        if !passed { exit(EXIT_FAILURE) }
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
