import Foundation

/// rex-reviewer's ledger. docs/ledger.md is the contract.
enum Paths {
    static let stateDir = ProcessInfo.processInfo.environment["REX_REVIEWER_STATE_DIR"]
        ?? NSHomeDirectory() + "/.local/state/rex-reviewer"
    static let reposDir = stateDir + "/repos"
    static let checkNow = stateDir + "/check-now"
}

/// One PR, repos/<owner>/<name>/pr-<n>.json.
struct Entry: Decodable, Identifiable, Equatable, Sendable {
    let repo: String
    let pr: Int
    var title: String?
    var author: String?
    var url: String?
    var state: String?
    var phase: String?
    var round: Int?
    var trigger: String?
    var verdict: String?
    var mergeRisk: String?
    var reviewURL: String?
    var worktree: String?
    var startedAt: String?
    var postedAt: String?
    var startError: String?

    var id: String { "\(repo)#\(pr)" }
    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var actionArgs: [String] { ["pr=\(pr)", "repo=\(repo)"] }

    enum CodingKeys: String, CodingKey {
        case repo, pr, title, author, url, state, phase, round, trigger, verdict, worktree
        case mergeRisk = "merge_risk"
        case reviewURL = "review_url"
        case startedAt = "started_at"
        case postedAt = "posted_at"
        case startError = "start_error"
    }

    /// Merged or closed, and cleaned up.
    var isFinished: Bool { ["cleaned", "merged", "closed"].contains(state ?? "") }
}

/// state.json.
struct PipelineState: Decodable, Equatable, Sendable {
    var paused: Bool?
    var stopped: Bool?
    var lastScanAt: String?
    var watchScript: String?
    var login: String?

    enum CodingKeys: String, CodingKey {
        case paused, stopped, login
        case lastScanAt = "last_scan_at"
        case watchScript = "watch_script"
    }
}

/// One item of watcher.json's attention list.
struct Attention: Decodable, Identifiable, Equatable, Sendable {
    let repo: String
    let pr: Int
    let kind: String
    let text: String
    var id: String { "\(repo)#\(pr):\(kind)" }
}

/// watcher.json.
struct WatcherInfo: Decodable, Equatable, Sendable {
    var at: String?
    var attention: [Attention]
    var checkFailed: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case at, attention, error
        case checkFailed = "check_failed"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try? c.decodeIfPresent(String.self, forKey: .at)
        // Lua writes an empty list as {}.
        attention = (try? c.decodeIfPresent([Attention].self, forKey: .attention)) ?? []
        checkFailed = try? c.decodeIfPresent(String.self, forKey: .checkFailed)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }
}

enum WatcherStatus {
    case watching, paused, stopped, down, failing
}

extension String {
    var isoDate: Date? { try? Date(self, strategy: .iso8601) }
}

enum Format {
    /// "now", "6m", "2h", "3d".
    static func short(since date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        default: return "\(s / 86400)d"
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = short(since: date, now: now)
        return s == "now" ? "just now" : s + " ago"
    }
}
