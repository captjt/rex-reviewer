import AppKit
import SwiftUI

struct RecapView: View {
    let store: Store
    let range: RecapRange
    let now: Date
    @State private var copied = false

    var body: some View {
        let recap = store.recap(range, now: now)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatTile(
                    label: "Reviews",
                    value: recap.reviews.count,
                    note: Recap.delta(recap.reviews.count, recap.previousReviews, range),
                    days: recap.perDay
                )
                StatTile(label: "Approved", value: recap.approved, note: share(recap.approved, of: recap.reviews.count))
                StatTile(label: "Changes requested", value: recap.changesRequested, note: share(recap.changesRequested, of: recap.reviews.count))
                StatTile(label: "Merged", value: recap.merged.count, note: Recap.delta(recap.merged.count, recap.previousMerged, range))
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 4)

            if let line = summary(recap) {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }

            if recap.isEmpty {
                Text(range == .today ? "No reviews yet today" : "No reviews in this range")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }

            VStack(alignment: .leading, spacing: 1) {
                if !recap.merged.isEmpty {
                    SectionTitle("Merged · \(recap.merged.count)")
                    ForEach(recap.merged, id: \.entry.id) { m in
                        RecapRow(store: store, entry: m.entry, at: m.at, now: now, detail: mergedDetail(m.entry))
                    }
                }
                if !recap.open.isEmpty {
                    SectionTitle("Still open · \(recap.open.count)")
                    ForEach(recap.open, id: \.entry.id) { o in
                        RecapRow(store: store, entry: o.entry, at: o.last.at, now: now, detail: openDetail(o.entry, o.last))
                    }
                }
                if !recap.closed.isEmpty {
                    SectionTitle("Closed without merging · \(recap.closed.count)")
                    ForEach(recap.closed, id: \.entry.id) { c in
                        RecapRow(store: store, entry: c.entry, at: c.at, now: now, detail: closedDetail(c.entry), dimmed: true)
                    }
                }
            }
            .padding(.horizontal, 6)

            if !recap.isEmpty {
                HStack {
                    Spacer()
                    FooterButton(
                        title: copied ? "Copied" : "Copy as Markdown",
                        symbol: copied ? "checkmark" : "doc.on.doc",
                        busy: false,
                        help: "Copy this recap as Markdown, for a standup or a weekly note"
                    ) {
                        store.copy(recap.markdown(multiRepo: store.multiRepo))
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func share(_ n: Int, of total: Int) -> String {
        total == 0 ? "of 0 reviews" : "\(Int((Double(n) / Double(total) * 100).rounded()))% of reviews"
    }

    private func summary(_ recap: Recap) -> String? {
        var bits: [String] = []
        if let wait = recap.medianWait {
            bits.append("Median time from request to review: \(Format.duration(wait))")
        }
        if recap.dismissed > 0 {
            bits.append("\(recap.dismissed) dismissed")
        }
        if let tokens = recap.tokenLine {
            bits.append(tokens)
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private func byline(_ e: Entry) -> String {
        var bits: [String] = []
        if store.multiRepo { bits.append(e.repoName) }
        if let author = e.author { bits.append("@" + author) }
        if let a = e.additions, let d = e.deletions { bits.append("+\(a) −\(d)") }
        return bits.joined(separator: " · ")
    }

    private func mergedDetail(_ e: Entry) -> String {
        let n = e.rounds.filter(\.isPosted).count
        var bits = [Recap.path(e), "\(n) round\(n == 1 ? "" : "s")"]
        if let risk = e.mergeRisk { bits.append("\(risk) risk") }
        if let tokens = Recap.tokens(e) { bits.append(tokens) }
        let by = byline(e)
        if !by.isEmpty { bits.append(by) }
        return bits.joined(separator: " · ")
    }

    private func closedDetail(_ e: Entry) -> String {
        ([Recap.tokens(e)].compactMap { $0 } + [byline(e)].filter { !$0.isEmpty }).joined(separator: " · ")
    }

    private func openDetail(_ e: Entry, _ last: Recap.Review) -> String {
        let waiting = last.round.verdict == "APPROVED" ? "approved, not merged yet" : "changes requested, waiting on the author"
        var bits = [waiting]
        if let b = last.round.blocking, b > 0 { bits.append("\(b) blocking") }
        if let tokens = Recap.tokens(e) { bits.append(tokens + " so far") }
        let by = byline(e)
        if !by.isEmpty { bits.append(by) }
        return bits.joined(separator: " · ")
    }
}

/// A label, a value in the text's own color, a note, and for Reviews a
/// sparkline of reviews per day.
struct StatTile: View {
    let label: String
    let value: Int
    let note: String
    var days: [Recap.Day]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "\(value)")
                .font(.title2.weight(.semibold))
            if let days, days.count > 1 {
                Sparkline(values: days.map(\.count))
                    .frame(height: 14)
                    .help(dayList(days))
            }
            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    private func dayList(_ days: [Recap.Day]) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(days.count > 8 ? "MMM d" : "EEE")
        return days.map { "\(f.string(from: $0.start)): \($0.count)" }.joined(separator: "\n")
    }
}

/// A thin line in the de-emphasis color, with today's point in the accent.
struct Sparkline: View {
    let values: [Int]

    var body: some View {
        GeometryReader { geo in
            let maxValue = max(values.max() ?? 0, 1)
            let step = geo.size.width / CGFloat(max(values.count - 1, 1))
            let point = { (i: Int) -> CGPoint in
                CGPoint(
                    x: CGFloat(i) * step,
                    y: geo.size.height - 2 - (geo.size.height - 4) * CGFloat(values[i]) / CGFloat(maxValue)
                )
            }
            ZStack {
                Path { p in
                    for i in values.indices {
                        if i == 0 { p.move(to: point(i)) } else { p.addLine(to: point(i)) }
                    }
                }
                .stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if let last = values.indices.last {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .position(point(last))
                }
            }
        }
    }
}

struct RecapRow: View {
    let store: Store
    let entry: Entry
    let at: Date
    let now: Date
    let detail: String
    var dimmed = false

    var body: some View {
        let verdict = Verdict(entry.rounds.last(where: \.isPosted)?.verdict ?? entry.verdict)
        RowButton(help: "Open the PR on GitHub") {
            store.open(entry.url)
        } content: {
            RowLayout(
                number: entry.pr,
                title: entry.title ?? "",
                trailing: Format.short(since: at, now: now),
                dimmed: dimmed
            ) {
                Image(systemName: verdict.symbol).foregroundStyle(verdict.color)
            } detail: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail).lineLimit(1)
                    if let about = entry.implementation {
                        Text(about)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .contextMenu { LinkMenu(store: store, entry: entry) }
    }
}
