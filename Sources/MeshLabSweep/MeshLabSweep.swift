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
            let result: SweepBatchResult
            if !arguments.mergeResults.isEmpty {
                let parts = try arguments.mergeResults.map { path in
                    try SweepJobFile.decodeResult(
                        Data(contentsOf: URL(fileURLWithPath: path))
                    )
                }
                result = try SweepRunner.merge(parts, for: job)
            } else {
                let previous: SweepBatchResult?
                if let resume = arguments.resume {
                    previous = try SweepJobFile.decodeResult(
                        Data(contentsOf: URL(fileURLWithPath: resume))
                    )
                } else {
                    previous = nil
                }
                let checkpointWriter: CheckpointWriter? = arguments.checkpoint.map {
                    CheckpointWriter(path: $0)
                }
                let checkpointHandler: (@Sendable (SweepCheckpoint) async -> Void)?
                if let checkpointWriter {
                    checkpointHandler = { checkpoint in
                        await checkpointWriter.write(checkpoint)
                    }
                } else {
                    checkpointHandler = nil
                }
                result = await SweepRunner.run(
                    job,
                    maxConcurrency: arguments.concurrency,
                    resuming: previous,
                    retryFailures: arguments.retryFailures,
                    shardIndex: arguments.shardIndex,
                    shardCount: arguments.shardCount,
                    checkpoint: checkpointHandler
                )
                try await checkpointWriter?.finish()
            }
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
        var resume: String?
        var retryFailures: Bool
        var checkpoint: String?
        var shardIndex: Int
        var shardCount: Int
        var mergeResults: [String]

        init(_ values: [String]) throws {
            var input: String?
            var output: String?
            var concurrency = max(1, ProcessInfo.processInfo.activeProcessorCount)
            var resume: String?
            var retryFailures = false
            var checkpoint: String?
            var shardIndex = 0
            var shardCount = 1
            var mergeResults: [String] = []
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
                case "--resume":
                    guard let value = iterator.next() else {
                        throw CLIError.invalidArguments(
                            "--resume needs a previous result path"
                        )
                    }
                    resume = value
                case "--retry-failures":
                    retryFailures = true
                case "--checkpoint":
                    guard let value = iterator.next() else {
                        throw CLIError.invalidArguments(
                            "--checkpoint needs a file path"
                        )
                    }
                    checkpoint = value
                case "--shard-index":
                    guard let raw = iterator.next(), let value = Int(raw), value >= 0 else {
                        throw CLIError.invalidArguments(
                            "--shard-index needs a non-negative integer"
                        )
                    }
                    shardIndex = value
                case "--shard-count":
                    guard let raw = iterator.next(), let value = Int(raw), value > 0 else {
                        throw CLIError.invalidArguments(
                            "--shard-count needs a positive integer"
                        )
                    }
                    shardCount = value
                case "--merge-result":
                    guard let value = iterator.next() else {
                        throw CLIError.invalidArguments(
                            "--merge-result needs a result file path"
                        )
                    }
                    mergeResults.append(value)
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
            self.resume = resume
            self.retryFailures = retryFailures
            guard shardIndex < shardCount else {
                throw CLIError.invalidArguments(
                    "--shard-index must be smaller than --shard-count"
                )
            }
            self.checkpoint = checkpoint
            self.shardIndex = shardIndex
            self.shardCount = shardCount
            self.mergeResults = mergeResults
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
                       [--resume previous-result.json] [--retry-failures]
                       [--checkpoint partial-result.json]
                       [--shard-index N --shard-count N]
                       [--merge-result shard.json ...]
                """
            case .invalidArguments(let message):
                return message
            }
        }
    }
}

private actor CheckpointWriter {
    let path: String
    var failure: String?

    init(path: String) {
        self.path = path
    }

    func write(_ checkpoint: SweepCheckpoint) {
        guard failure == nil else { return }
        do {
            let data = try SweepJobFile.encode(checkpoint.result)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            failure = String(describing: error)
        }
    }

    func finish() throws {
        if let failure {
            throw CheckpointError.writeFailed(failure)
        }
    }

    enum CheckpointError: Error {
        case writeFailed(String)
    }
}
