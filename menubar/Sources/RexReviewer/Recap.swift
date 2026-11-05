import Foundation

enum RecapRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "This week"
    case month = "30 days"

    var id: Self { self }

    /// What the change is measured against, as the tiles say it.
    var previousName: String {
        switch self {
        case .today: "yesterday"
        case .week: "last week"
        case .month: "the 30 days before"
        }
    }
}

/// What happened in a range: the reviews the agents posted, and how the PRs
/// they reviewed ended. Built from the ledger's history records.
struct Recap {
    struct Review {
        let entry: Entry
        let round: Round
        let at: Date
    }

    struct Day: Identifiable {
        let start: Date
        let count: Int
        var id: Date { start }
    }

    let range: RecapRange
    let start: Date
    let now: Date
    let reviews: [Review]
    let previousReviews: Int
    let dismissed: Int
    let merged: [(entry: Entry, at: Date)]
    let previousMerged: Int
    let closed: [(entry: Entry, at: Date)]
    let open: [(entry: Entry, last: Review)]
    /// Reviews posted each day; nil for Today.
    let perDay: [Day]?
    /// The median time from a round's request to its review.
    let medianWait: TimeInterval?
    /// What the agents spent in the rounds that ended in the range, posted
    /// or dismissed, and how much of it was cached input.
    let tokens: Int
    let cachedTokens: Int

    var approved: Int { reviews.filter { $0.round.verdict == "APPROVED" }.count }
    var changesRequested: Int { reviews.filter { $0.round.verdict == "CHANGES_REQUESTED" }.count }
    var isEmpty: Bool { reviews.isEmpty && merged.isEmpty && closed.isEmpty && dismissed == 0 }

    init(range: RecapRange, entries: [Entry], endings: (Entry) -> Ending?, now: Date, calendar: Calendar = .current) {
        self.range = range
        self.now = now
        let start: Date
        let previousStart: Date
        switch range {
        case .today:
            start = calendar.startOfDay(for: now)
            previousStart = calendar.date(byAdding: .day, value: -1, to: start)!
        case .week:
            start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            previousStart = calendar.date(byAdding: .day, value: -7, to: start)!
        case .month:
            start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
            previousStart = calendar.date(byAdding: .day, value: -30, to: start)!
        }
        self.start = start

        var reviews: [Review] = []
        var previous = 0
        var dismissed = 0
        var tokens = 0
        var cachedTokens = 0
        for e in entries {
            for r in e.rounds {
                guard let at = r.at?.isoDate else { continue }
                if at >= start {
                    tokens += r.tokens?.total ?? 0
                    cachedTokens += r.tokens?.cacheRead ?? 0
                }
                if r.verdict == "DISMISSED" {
                    if at >= start { dismissed += 1 }
                } else if r.isPosted {
                    if at >= start {
                        reviews.append(Review(entry: e, round: r, at: at))
                    } else if at >= previousStart {
                        previous += 1
                    }
                }
            }
        }
        reviews.sort { $0.at > $1.at }
        self.reviews = reviews
        self.previousReviews = previous
        self.dismissed = dismissed
        self.tokens = tokens
        self.cachedTokens = cachedTokens

        var merged: [(entry: Entry, at: Date)] = []
        var closed: [(entry: Entry, at: Date)] = []
        var previousMerged = 0
        // Only PRs the agents reviewed count; the ledger also tracks requests
        // that never got a round.
        for e in entries where e.rounds.contains(where: \.isPosted) {
            guard let end = endings(e) else { continue }
            if end.at >= start {
                if end.outcome == "merged" { merged.append((e, end.at)) } else { closed.append((e, end.at)) }
            } else if end.at >= previousStart, end.outcome == "merged" {
                previousMerged += 1
            }
        }
        self.merged = merged.sorted { $0.at > $1.at }
        self.closed = closed.sorted { $0.at > $1.at }
        self.previousMerged = previousMerged

        // Reviewed in this range, and still open.
        var latest: [String: Review] = [:]
        for r in reviews where endings(r.entry) == nil {
            if latest[r.entry.id] == nil { latest[r.entry.id] = r }
        }
        self.open = latest.values.sorted { $0.at > $1.at }.map { ($0.entry, $0) }

        if range == .today {
            perDay = nil
        } else {
            var days: [Day] = []
            var day = start
            while day <= now {
                let next = calendar.date(byAdding: .day, value: 1, to: day)!
                days.append(Day(start: day, count: reviews.filter { $0.at >= day && $0.at < next }.count))
                day = next
            }
            perDay = days
        }

        let waits = reviews.compactMap { r -> TimeInterval? in
            guard let asked = r.round.requestedAt?.isoDate else { return nil }
            return r.at.timeIntervalSince(asked)
        }.sorted()
        if waits.isEmpty {
            medianWait = nil
        } else if waits.count % 2 == 1 {
            medianWait = waits[waits.count / 2]
        } else {
            medianWait = (waits[waits.count / 2 - 1] + waits[waits.count / 2]) / 2
        }
    }

    /// "+3 vs last week", "same as yesterday".
    static func delta(_ now: Int, _ before: Int, _ range: RecapRange) -> String {
        let d = now - before
        if d == 0 { return "same as \(range.previousName)" }
        return (d > 0 ? "+\(d)" : "−\(-d)") + " vs \(range.previousName)"
    }

    /// The verdicts of every posted round, oldest first, such as "✕ → ✓".
    static func path(_ e: Entry) -> String {
        e.rounds.filter(\.isPosted).map { r in
            switch r.verdict {
            case "APPROVED": "✓"
            case "CHANGES_REQUESTED": "✕"
            default: "•"
            }
        }.joined(separator: " → ")
    }

    /// "5.8M tokens": what the agents have spent on the PR, all rounds together.
    static func tokens(_ e: Entry) -> String? {
        guard let t = e.tokens?.total, t > 0 else { return nil }
        return Format.tokens(t) + " tokens"
    }

    /// "52M tokens, 96% cached", for the rounds in the range.
    var tokenLine: String? {
        guard tokens > 0 else { return nil }
        let cached = Int((Double(cachedTokens) / Double(tokens) * 100).rounded())
        return "\(Format.tokens(tokens)) tokens, \(cached)% cached"
    }

    var title: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        let from = f.string(from: start)
        let to = f.string(from: now)
        return range == .today ? "Today, \(to)" : "\(range.rawValue), \(from) to \(to)"
    }

    /// A summary for a standup or a weekly note.
    func markdown(multiRepo: Bool) -> String {
        func link(_ e: Entry) -> String {
            let name = multiRepo ? "\(e.repo)#\(e.pr)" : "#\(e.pr)"
            return e.url.map { "[\(name)](\($0))" } ?? name
        }
        func by(_ e: Entry) -> String { e.author.map { " by @\($0)" } ?? "" }
        // What the PR changes, as a nested bullet under its line.
        func about(_ e: Entry) -> [String] { e.implementation.map { ["  - \($0)"] } ?? [] }

        var out = ["**PR reviews: \(title)**", ""]
        var line = "\(reviews.count) review\(reviews.count == 1 ? "" : "s") posted: \(approved) approved, \(changesRequested) changes requested."
        line += " \(merged.count) PR\(merged.count == 1 ? "" : "s") merged."
        if let wait = medianWait { line += " Median time from request to review: \(Format.duration(wait))." }
        if let t = tokenLine { line += " The agents used \(t)." }
        out.append(line)
        if !merged.isEmpty {
            out += ["", "Merged:"]
            for m in merged {
                let n = m.entry.rounds.filter(\.isPosted).count
                var bits = ["\(Recap.path(m.entry)) in \(n) round\(n == 1 ? "" : "s")"]
                if let risk = m.entry.mergeRisk { bits.append("\(risk) merge risk") }
                if let t = Recap.tokens(m.entry) { bits.append(t) }
                out.append("- \(link(m.entry)) \(m.entry.title ?? "")\(by(m.entry)): \(bits.joined(separator: ", "))")
                out += about(m.entry)
            }
        }
        if !open.isEmpty {
            out += ["", "Still open:"]
            for o in open {
                let verdict = Verdict(o.last.round.verdict).label.lowercased()
                out.append("- \(link(o.entry)) \(o.entry.title ?? "")\(by(o.entry)): \(verdict) \(Format.ago(o.last.at, now: now))"
                    + (Recap.tokens(o.entry).map { ", \($0) so far" } ?? ""))
                out += about(o.entry)
            }
        }
        if !closed.isEmpty {
            out += ["", "Closed without merging:"]
            for c in closed {
                out.append("- \(link(c.entry)) \(c.entry.title ?? "")\(by(c.entry))" + (Recap.tokens(c.entry).map { ": \($0)" } ?? ""))
                out += about(c.entry)
            }
        }
        return out.joined(separator: "\n")
    }
}
