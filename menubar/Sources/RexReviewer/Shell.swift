import Foundation

enum Shell {
    struct Result: Sendable {
        let status: Int32
        let output: String
        let error: String

        /// The first line of what went wrong, without rex's "Error: ".
        var failure: String {
            let text = (error.isEmpty ? output : error).trimmingCharacters(in: .whitespacesAndNewlines)
            let line = text.split(separator: "\n").first.map(String.init) ?? "failed with status \(status)"
            return line.hasPrefix("Error: ") ? String(line.dropFirst(7)) : line
        }
    }

    /// lib.lua's M.PATH. An app opened from Finder gets only the system
    /// directories, and rex and rex-agent live elsewhere.
    static let path: String = {
        let home = NSHomeDirectory()
        return [
            home + "/.bin",
            "/opt/homebrew/bin",
            home + "/.nix-profile/bin",
            "/etc/profiles/per-user/\(NSUserName())/bin",
            "/run/current-system/sw/bin",
            home + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS",
            "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
    }()

    /// Run a command to the end. Call it off the main actor.
    static func run(_ executable: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "", error: error.localizedDescription)
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self),
            error: String(decoding: errors, as: UTF8.self)
        )
    }

    static func rex(_ arguments: [String]) -> Result {
        run("/usr/bin/env", ["rex"] + arguments)
    }
}
