import AppKit
import Foundation
import Darwin

@main
enum CodexTokenBarApp {
    static func main() {
        do {
            let configuration = try AppConfiguration.parse(Array(CommandLine.arguments.dropFirst()))
            if configuration.showHelp {
                print(AppConfiguration.help)
            } else if configuration.reportOnly {
                let report = try ReportBuilder(configuration: configuration).scan()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(report)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                let app = NSApplication.shared
                let delegate = StatusBarController(configuration: configuration)
                app.delegate = delegate
                withExtendedLifetime(delegate) { app.run() }
            }
        } catch {
            FileHandle.standardError.write(Data("CodexTokenBar: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
