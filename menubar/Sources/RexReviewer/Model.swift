import Foundation

/// rex-reviewer's ledger. docs/ledger.md is the contract.
enum Paths {
    static let stateDir = ProcessInfo.processInfo.environment["REX_REVIEWER_STATE_DIR"]
        ?? NSHomeDirectory() + "/.local/state/rex-reviewer"
    static let reposDir = stateDir + "/repos"
    static let checkNow = stateDir + "/check-now"

    /// rex-inbox's hub, when it runs: the same paths rex-inbox uses.
    static let inboxSocket: String = {
        let env = ProcessInfo.processInfo.environment
        if let s = env["REX_INBOX_SOCKET"] { return s }
        return (env["REX_INBOX_STATE"] ?? NSHomeDirectory() + "/.local/state/rex-inbox") + "/hub.sock"
    }()
}

/// Whether the menu bar icon turns orange for what needs you.
enum BadgeMode: String, Sendable {
    /// Unless rex-inbox's hub is running: it alerts you to the same items,
    /// from the watcher's status records, and lets you act on them.
    case automatic
    case always
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
    /// While reviewing: how many of the round's reviewers are done, of how many.
    var reviewersDone: Int?
    var reviewersTotal: Int?
    var round: Int?
    var trigger: String?
    var verdict: String?
    var mergeRisk: String?
    var reviewURL: String?
    var worktree: String?
    var startedAt: String?
    var postedAt: String?
    var startError: String?
    var outcome: String?
    var endedAt: String?
    var requestedAt: String?
    var additions: Int?
    var deletions: Int?
    /// What the PR changes, in a sentence or two from the last round's draft.
    var implementation: String?
    /// What the agents have spent on the PR so far, all rounds together.
    var tokens: PRTokens?
    var history: LenientList<Round>?

    var id: String { "\(repo)#\(pr)" }
    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var actionArgs: [String] { ["pr=\(pr)", "repo=\(repo)"] }
    var rounds: [Round] { history?.items ?? [] }

    enum CodingKeys: String, CodingKey {
        case repo, pr, title, author, url, state, phase, round, trigger, verdict, worktree, outcome
        case additions, deletions, implementation, tokens, history
        case mergeRisk = "merge_risk"
        case reviewURL = "review_url"
        case startedAt = "started_at"
        case postedAt = "posted_at"
        case startError = "start_error"
        case endedAt = "ended_at"
        case requestedAt = "requested_at"
        case reviewersDone = "reviewers_done"
        case reviewersTotal = "reviewers_total"
    }

    /// Merged or closed, and cleaned up.
    var isFinished: Bool { ["cleaned", "merged", "closed"].contains(state ?? "") }
}

/// One finished round, from an entry's history.
struct Round: Decodable, Equatable, Sendable {
    var round: Int?
    var verdict: String?
    var by: String?
    var at: String?
    var url: String?
    var requestedAt: String?
    var startedAt: String?
    var blocking: Int?
    var nonBlocking: Int?
    var mergeRisk: String?
    /// What the agents spent in this round.
    var tokens: TokenCount?

    enum CodingKeys: String, CodingKey {
        case round, verdict, by, at, url, blocking, tokens
        case requestedAt = "requested_at"
        case startedAt = "started_at"
        case nonBlocking = "non_blocking"
        case mergeRisk = "merge_risk"
    }

    /// A review the agents posted, rather than a dismissal or your own review.
    var isPosted: Bool { by == "agents" || by == "codex" }
}

/// Tokens as bin/token-usage counts them. input is what wasn't cached.
struct TokenCount: Decodable, Equatable, Sendable {
    var input: Int?
    var cacheRead: Int?
    var cacheWrite: Int?
    var output: Int?
    var total: Int?

    enum CodingKeys: String, CodingKey {
        case input, output, total
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }
}

/// bin/token-usage's output for a PR: each agent's count, and their total.
struct PRTokens: Decodable, Equatable, Sendable {
    var codex: TokenCount?
    var claude: TokenCount?
    var total: Int?
}

/// A JSON list that Lua may have written as {} when it was empty.
struct LenientList<T: Decodable & Equatable & Sendable>: Decodable, Equatable, Sendable {
    var items: [T]

    init(from decoder: any Decoder) throws {
        items = (try? decoder.singleValueContainer().decode([T].self)) ?? []
    }
}

/// How a PR ended, from an entry or, for older entries, events.jsonl.
struct Ending: Equatable, Sendable {
    let outcome: String
    let at: Date
}

/// state.json.
struct PipelineState: Decodable, Equatable, Sendable {
    var paused: Bool?
    var stopped: Bool?
    var lastScanAt: String?
    var watchScript: String?
    var login: String?
    /// Where the watcher runs: "rex" (or nil, before hosts) or "herdr".
    var host: String?

    enum CodingKeys: String, CodingKey {
        case paused, stopped, login, host
        case lastScanAt = "last_scan_at"
        case watchScript = "watch_script"
    }

    var onHerdr: Bool { host == "herdr" }

    /// The app that shows the panes, by name.
    var hostApp: String { onHerdr ? "Herdr" : "Rex" }

    /// The checkout the watcher runs from: the folder above its script's.
    var root: String? {
        guard let script = watchScript else { return nil }
        let url = URL(fileURLWithPath: script)
        return url.deletingLastPathComponent().deletingLastPathComponent().path
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

    /// "940", "812K", "5.8M", "17M", "1.2B".
    static func tokens(_ n: Int) -> String {
        func scaled(_ unit: Double, _ suffix: String) -> String {
            let v = Double(n) / unit
            return String(format: v < 10 ? "%.1f" : "%.0f", v) + suffix
        }
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return "\(n / 1_000)K"
        case ..<1_000_000_000: return scaled(1_000_000, "M")
        default: return scaled(1_000_000_000, "B")
        }
    }

    /// "25m", "1h 40m", "2d 3h".
    static func duration(_ seconds: TimeInterval) -> String {
        let m = max(0, Int(seconds / 60))
        if m < 60 { return "\(max(m, 1))m" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        return h % 24 == 0 ? "\(h / 24)d" : "\(h / 24)d \(h % 24)h"
    }
}
