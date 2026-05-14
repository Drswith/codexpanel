import Foundation

enum CLIExitCode: Int32 {
    case success = 0
    case invalidArguments = 2
    case appUnavailable = 3
    case accessibilityDenied = 4
    case waitTimeout = 5
    case routeUnsupported = 6
    case unknown = 1
}

struct CLIError: LocalizedError {
    let code: CLIExitCode
    let message: String
    let hint: String?
    let jsonOutput: Bool

    init(
        code: CLIExitCode,
        message: String,
        hint: String? = nil,
        jsonOutput: Bool = false
    ) {
        self.code = code
        self.message = message
        self.hint = hint
        self.jsonOutput = jsonOutput
    }

    var errorDescription: String? {
        self.message
    }
}

struct CLIErrorPayload: Encodable {
    struct Body: Encodable {
        var code: Int
        var message: String
        var hint: String?

        enum CodingKeys: String, CodingKey {
            case code
            case message
            case hint
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.code, forKey: .code)
            try container.encode(self.message, forKey: .message)
            if let hint = self.hint {
                try container.encode(hint, forKey: .hint)
            } else {
                try container.encodeNil(forKey: .hint)
            }
        }
    }

    var error: Body
}

