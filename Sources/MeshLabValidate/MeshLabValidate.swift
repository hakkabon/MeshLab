import Darwin
import Foundation
import MeshLabCore

@main
enum MeshLabValidateCommand {
    static func main() throws {
        let report = try MeshLabValidation.runStandardSuite()
        let data = try report.jsonData(prettyPrinted: true)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if !report.passed { exit(EXIT_FAILURE) }
    }
}
