import Foundation

enum CLIUsage {
    static let text = """
Usage:
  codexpanel view open settings [--page accounts|records|usage|diagnostics|about] [--wait <sec>] [--json]
  codexpanel view open menu [--wait <sec>] [--json]
  codexpanel view open login [--wait <sec>] [--json]
  codexpanel view close settings|menu|login|all [--wait <sec>] [--json]
  codexpanel state [--json]
  codexpanel snapshot [--format tree|json] [--target auto|settings|menu|login|all]
  codexpanel doctor [--json]
"""
}

enum CLIArgumentParser {
    static func parse(arguments: [String]) throws -> CLICommand {
        guard let command = arguments.first else {
            throw CLIError(
                code: .invalidArguments,
                message: CLIUsage.text
            )
        }
        let remaining = Array(arguments.dropFirst())
        switch command {
        case "view":
            return .view(try self.parseView(arguments: remaining))
        case "state":
            return .state(try self.parseState(arguments: remaining))
        case "snapshot":
            return .snapshot(try self.parseSnapshot(arguments: remaining))
        case "doctor":
            return .doctor(try self.parseDoctor(arguments: remaining))
        case "--help", "-h", "help":
            throw CLIError(code: .invalidArguments, message: CLIUsage.text)
        default:
            throw CLIError(
                code: .invalidArguments,
                message: "Unknown command: \(command)\n\n\(CLIUsage.text)"
            )
        }
    }

    private static func parseView(arguments: [String]) throws -> ViewCommand {
        let requestedJSON = arguments.contains("--json")
        guard arguments.count >= 2 else {
            throw CLIError(
                code: .invalidArguments,
                message: "view requires <open|close> and a target.\n\n\(CLIUsage.text)",
                jsonOutput: requestedJSON
            )
        }
        guard let action = ViewAction(rawValue: arguments[0]) else {
            throw CLIError(
                code: .invalidArguments,
                message: "Invalid view action: \(arguments[0])",
                jsonOutput: requestedJSON
            )
        }
        guard let target = ViewTarget(rawValue: arguments[1]) else {
            throw CLIError(
                code: .invalidArguments,
                message: "Invalid view target: \(arguments[1])",
                jsonOutput: requestedJSON
            )
        }
        if action == .open, target == .all {
            throw CLIError(
                code: .routeUnsupported,
                message: "view open all is not supported in V1.",
                jsonOutput: requestedJSON
            )
        }

        var page: CLISettingsPage?
        var waitSeconds: TimeInterval?
        var jsonOutput = false

        var index = 2
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--page":
                guard action == .open, target == .settings else {
                    throw CLIError(
                        code: .invalidArguments,
                        message: "--page is only valid for `view open settings`.",
                        jsonOutput: requestedJSON
                    )
                }
                guard index + 1 < arguments.count else {
                    throw CLIError(
                        code: .invalidArguments,
                        message: "--page requires a value.",
                        jsonOutput: requestedJSON
                    )
                }
                let rawPage = arguments[index + 1]
                let normalizedPage = rawPage == "updates" ? "about" : rawPage
                guard let parsedPage = CLISettingsPage(rawValue: normalizedPage) else {
                    throw CLIError(
                        code: .invalidArguments,
                        message: "Invalid settings page: \(rawPage)",
                        jsonOutput: requestedJSON
                    )
                }
                page = parsedPage
                index += 2
            case "--wait":
                guard index + 1 < arguments.count else {
                    throw CLIError(
                        code: .invalidArguments,
                        message: "--wait requires a value.",
                        jsonOutput: requestedJSON
                    )
                }
                guard let seconds = TimeInterval(arguments[index + 1]), seconds >= 0 else {
                    throw CLIError(
                        code: .invalidArguments,
                        message: "Invalid --wait value: \(arguments[index + 1])",
                        jsonOutput: requestedJSON
                    )
                }
                waitSeconds = seconds
                index += 2
            case "--json":
                jsonOutput = true
                index += 1
            default:
                throw CLIError(
                    code: .invalidArguments,
                    message: "Unknown option for view: \(option)",
                    jsonOutput: requestedJSON
                )
            }
        }

        if action == .open, target == .settings, page == nil {
            page = .accounts
        }

        return ViewCommand(
            action: action,
            target: target,
            page: page,
            waitSeconds: waitSeconds,
            jsonOutput: jsonOutput
        )
    }

    private static func parseState(arguments: [String]) throws -> StateCommand {
        var jsonOutput = true
        for option in arguments {
            switch option {
            case "--json":
                jsonOutput = true
            default:
                throw CLIError(
                    code: .invalidArguments,
                    message: "Unknown option for state: \(option)",
                    jsonOutput: true
                )
            }
        }
        return StateCommand(jsonOutput: jsonOutput)
    }

    private static func parseSnapshot(arguments: [String]) throws -> SnapshotCommand {
        var format: SnapshotFormat = .tree
        var target: SnapshotTarget = .auto

        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--format":
                guard index + 1 < arguments.count else {
                    throw CLIError(code: .invalidArguments, message: "--format requires a value.")
                }
                let rawFormat = arguments[index + 1]
                guard let parsedFormat = SnapshotFormat(rawValue: rawFormat) else {
                    throw CLIError(code: .invalidArguments, message: "Invalid snapshot format: \(rawFormat)")
                }
                format = parsedFormat
                index += 2
            case "--target":
                guard index + 1 < arguments.count else {
                    throw CLIError(code: .invalidArguments, message: "--target requires a value.")
                }
                let rawTarget = arguments[index + 1]
                guard let parsedTarget = SnapshotTarget(rawValue: rawTarget) else {
                    throw CLIError(code: .invalidArguments, message: "Invalid snapshot target: \(rawTarget)")
                }
                target = parsedTarget
                index += 2
            default:
                throw CLIError(code: .invalidArguments, message: "Unknown option for snapshot: \(option)")
            }
        }

        return SnapshotCommand(format: format, target: target)
    }

    private static func parseDoctor(arguments: [String]) throws -> DoctorCommand {
        var jsonOutput = true
        for option in arguments {
            switch option {
            case "--json":
                jsonOutput = true
            default:
                throw CLIError(
                    code: .invalidArguments,
                    message: "Unknown option for doctor: \(option)",
                    jsonOutput: true
                )
            }
        }
        return DoctorCommand(jsonOutput: jsonOutput)
    }
}
