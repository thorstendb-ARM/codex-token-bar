import Foundation

struct AppConfiguration {
    let codexHomes: [URL]
    let cacheURL: URL
    let reportOnly: Bool
    let showHelp: Bool

    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> AppConfiguration {
        var homes: [URL] = []
        var cache: URL?
        var report = false
        var help = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--report":
                report = true
            case "--help", "-h":
                help = true
            case "--codex-home", "--cache":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty,
                      !arguments[index].hasPrefix("--") else {
                    throw ConfigurationError.message("Missing path after \(argument).")
                }
                let url = fileURL(arguments[index])
                if argument == "--codex-home" {
                    if !homes.contains(url) { homes.append(url) }
                } else {
                    cache = url
                }
            default:
                throw ConfigurationError.message("Unknown argument: \(argument). Use --help for usage.")
            }
            index += 1
        }

        if homes.isEmpty {
            if let configured = environment["CODEX_HOME"], !configured.isEmpty {
                homes = [fileURL(configured)]
            } else {
                homes = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)]
            }
        }

        let defaultCache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/CodexTokenBar", isDirectory: true)
            .appendingPathComponent("index.json")
        return AppConfiguration(codexHomes: homes, cacheURL: cache ?? defaultCache,
                                reportOnly: report, showHelp: help)
    }

    private static func fileURL(_ value: String) -> URL {
        URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
    }

    static let help = """
    Usage: CodexTokenBar [--report] [--codex-home PATH] [--cache PATH]

      --report            Print all five periods as JSON without opening the app.
                          Current uses the app's saved manual measurement start.
      --codex-home PATH   Read this Codex home; may be repeated for multiple homes.
                          Defaults to CODEX_HOME, or ~/.codex when unset.
      --cache PATH        Override ~/Library/Caches/CodexTokenBar/index.json.
      --help              Show this help.

    Costs are estimates in USD at standard API prices, not account billing.
    """
}

enum ConfigurationError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
