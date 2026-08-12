import Foundation

public enum CLICommand: Equatable, Sendable {
    case help
    case configInit(path: String?)
    case configValidate(path: String?)
    case doctor(path: String?, synthesize: Bool)
    case devices
    case run(path: String?, showTranscript: Bool)
    case replay(input: String, path: String?, synthesize: Bool, liveOutput: Bool)
    case report(session: String, path: String?, json: Bool)
}

public struct CLIUsageError: Error, Equatable, Sendable {
    public static let exitCode: Int32 = 64

    public init() {}
}

public enum CLIParser {
    public static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let command = arguments.first else {
            throw CLIUsageError()
        }
        switch command {
        case "help", "--help", "-h":
            guard arguments.count == 1 else { throw CLIUsageError() }
            return .help
        case "devices":
            guard arguments.count == 1 else { throw CLIUsageError() }
            return .devices
        case "config":
            return try parseConfig(Array(arguments.dropFirst()))
        case "doctor":
            let options = try parseOptions(
                Array(arguments.dropFirst()), allowedFlags: ["--synthesize"])
            return .doctor(path: options.path, synthesize: options.flags.contains("--synthesize"))
        case "run":
            let options = try parseOptions(
                Array(arguments.dropFirst()),
                allowedFlags: ["--show-transcript"]
            )
            return .run(
                path: options.path,
                showTranscript: options.flags.contains("--show-transcript")
            )
        case "replay":
            return try parseReplay(Array(arguments.dropFirst()))
        case "report":
            return try parseReport(Array(arguments.dropFirst()))
        default:
            throw CLIUsageError()
        }
    }

    private static func parseConfig(_ arguments: [String]) throws -> CLICommand {
        guard let subcommand = arguments.first, subcommand == "init" || subcommand == "validate"
        else {
            throw CLIUsageError()
        }
        let options = try parseOptions(Array(arguments.dropFirst()), allowedFlags: [])
        return subcommand == "init"
            ? .configInit(path: options.path)
            : .configValidate(path: options.path)
    }

    private static func parseReplay(_ arguments: [String]) throws -> CLICommand {
        guard let input = arguments.first, !input.hasPrefix("--") else {
            throw CLIUsageError()
        }
        let options = try parseOptions(
            Array(arguments.dropFirst()),
            allowedFlags: ["--synthesize", "--live-output"]
        )
        return .replay(
            input: input,
            path: options.path,
            synthesize: options.flags.contains("--synthesize"),
            liveOutput: options.flags.contains("--live-output")
        )
    }

    private static func parseReport(_ arguments: [String]) throws -> CLICommand {
        var remaining = arguments
        let session: String
        if let first = remaining.first, !first.hasPrefix("--") {
            session = first
            remaining.removeFirst()
        } else {
            session = "latest"
        }
        let options = try parseOptions(remaining, allowedFlags: ["--json"])
        return .report(session: session, path: options.path, json: options.flags.contains("--json"))
    }

    private static func parseOptions(
        _ arguments: [String],
        allowedFlags: Set<String>
    ) throws -> ParsedOptions {
        var path: String?
        var flags = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--path" {
                guard path == nil, index + 1 < arguments.count else { throw CLIUsageError() }
                let value = arguments[index + 1]
                guard !value.hasPrefix("--") else { throw CLIUsageError() }
                path = value
                index += 2
            } else if allowedFlags.contains(argument) {
                guard flags.insert(argument).inserted else { throw CLIUsageError() }
                index += 1
            } else {
                throw CLIUsageError()
            }
        }
        return ParsedOptions(path: path, flags: flags)
    }

    private struct ParsedOptions {
        let path: String?
        let flags: Set<String>
    }
}
