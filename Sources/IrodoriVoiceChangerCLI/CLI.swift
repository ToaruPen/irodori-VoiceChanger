import Foundation

public enum CLICommand: Equatable, Sendable {
    case help
    case configInit(path: String?)
    case configValidate(path: String?)
    case doctor(path: String?, synthesize: Bool)
    case devices
    case run(
        path: String?,
        showTranscript: Bool,
        shadowSynthesizePrefix: Bool,
        endpointShadowMilliseconds: Int?,
        shadowSmartTurn: Bool
    )
    case replay(
        input: String,
        path: String?,
        synthesize: Bool,
        liveOutput: Bool,
        shadowSynthesizePrefix: Bool,
        endpointShadowMilliseconds: Int?,
        earlyFinalizeShadowMilliseconds: Int?,
        smartTurnShadow: Bool
    )
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
                allowedFlags: [
                    "--show-transcript", "--shadow-synthesize-prefix", "--shadow-smart-turn",
                ],
                allowedValues: ["--shadow-endpoint-ms"]
            )
            let endpointShadowMilliseconds = try boundedMilliseconds(
                options,
                option: "--shadow-endpoint-ms"
            )
            let shadowSynthesizePrefix = options.flags.contains("--shadow-synthesize-prefix")
            let shadowSmartTurn = options.flags.contains("--shadow-smart-turn")
            guard
                !shadowSmartTurn
                    || (!shadowSynthesizePrefix && endpointShadowMilliseconds == nil)
            else {
                throw CLIUsageError()
            }
            return .run(
                path: options.path,
                showTranscript: options.flags.contains("--show-transcript"),
                shadowSynthesizePrefix: shadowSynthesizePrefix,
                endpointShadowMilliseconds: endpointShadowMilliseconds,
                shadowSmartTurn: shadowSmartTurn
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
            allowedFlags: [
                "--synthesize", "--live-output", "--shadow-synthesize-prefix",
                "--shadow-smart-turn",
            ],
            allowedValues: ["--shadow-endpoint-ms", "--shadow-early-finalize-ms"]
        )
        let synthesize = options.flags.contains("--synthesize")
        let liveOutput = options.flags.contains("--live-output")
        let shadowSynthesizePrefix = options.flags.contains("--shadow-synthesize-prefix")
        let smartTurnShadow = options.flags.contains("--shadow-smart-turn")
        let endpointShadowMilliseconds = try boundedMilliseconds(
            options,
            option: "--shadow-endpoint-ms"
        )
        let earlyFinalizeShadowMilliseconds = try boundedMilliseconds(
            options,
            option: "--shadow-early-finalize-ms"
        )
        guard !shadowSynthesizePrefix || synthesize else { throw CLIUsageError() }
        guard
            earlyFinalizeShadowMilliseconds == nil
                || (!synthesize && !liveOutput && !shadowSynthesizePrefix
                    && endpointShadowMilliseconds == nil)
        else {
            throw CLIUsageError()
        }
        guard
            !smartTurnShadow
                || (!synthesize && !liveOutput && !shadowSynthesizePrefix
                    && endpointShadowMilliseconds == nil
                    && earlyFinalizeShadowMilliseconds == nil)
        else {
            throw CLIUsageError()
        }
        return .replay(
            input: input,
            path: options.path,
            synthesize: synthesize,
            liveOutput: liveOutput,
            shadowSynthesizePrefix: shadowSynthesizePrefix,
            endpointShadowMilliseconds: endpointShadowMilliseconds,
            earlyFinalizeShadowMilliseconds: earlyFinalizeShadowMilliseconds,
            smartTurnShadow: smartTurnShadow
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
        allowedFlags: Set<String>,
        allowedValues: Set<String> = []
    ) throws -> ParsedOptions {
        var values = [String: String]()
        var flags = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--path" || allowedValues.contains(argument) {
                guard values[argument] == nil, index + 1 < arguments.count else {
                    throw CLIUsageError()
                }
                let value = arguments[index + 1]
                guard !value.hasPrefix("--") else { throw CLIUsageError() }
                values[argument] = value
                index += 2
            } else if allowedFlags.contains(argument) {
                guard flags.insert(argument).inserted else { throw CLIUsageError() }
                index += 1
            } else {
                throw CLIUsageError()
            }
        }
        return ParsedOptions(values: values, flags: flags)
    }

    private struct ParsedOptions {
        let values: [String: String]
        let flags: Set<String>

        var path: String? { values["--path"] }
    }

    private static func boundedMilliseconds(
        _ options: ParsedOptions,
        option: String
    ) throws -> Int? {
        guard let value = options.values[option] else { return nil }
        guard let milliseconds = Int(value), (100...3_000).contains(milliseconds) else {
            throw CLIUsageError()
        }
        return milliseconds
    }
}
