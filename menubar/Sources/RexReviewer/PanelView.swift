import AppKit
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case now = "Now"
    case recap = "Recap"

    var id: Self { self }
}

struct PanelView: View {
    let store: Store
    @AppStorage("panelTab") private var tab: PanelTab = .now
    @AppStorage("recapRange") private var range: RecapRange = .week
    @State private var listHeight: CGFloat = 0

    var body: some View {
        // Relative times refresh every 30 seconds.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                HeaderView(store: store, now: context.date, tab: $tab, range: $range)
                Divider()
                ScrollView {
                    Group {
                        switch tab {
                        case .now: SectionsView(store: store, now: context.date)
                        case .recap: RecapView(store: store, range: range, now: context.date)
                        }
                    }
                    .padding(.vertical, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(listHeight, 60), 520))
                if store.remoteControlOff {
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("Rex can't switch to the tab until Remote Control is on.")
                        Spacer(minLength: 4)
                        Button("Open Settings") { store.openRexServerSettings() }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                if let message = store.message {
                    Divider()
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                Divider()
                FooterView(store: store)
            }
        }
        .frame(width: 440)
    }
}

// MARK: Header

struct HeaderView: View {
    let store: Store
    let now: Date
    @Binding var tab: PanelTab
    @Binding var range: RecapRange

    var body: some View {
        let status = store.watcherStatus
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("Rex Reviewer").font(.headline)
                Spacer()
                Picker("View", selection: $tab) {
                    ForEach(PanelTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            switch tab {
            case .now:
                Button {
                    store.show(nil)
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(color(status)).frame(width: 7, height: 7)
                        Text(label(status))
                        if let scanned = store.state.lastScanAt?.isoDate, status != .stopped, status != .down {
                            Text("· checked \(Format.ago(scanned, now: now))")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(status == .stopped || status == .down)
                .help("Show the watcher in Rex")
            case .recap:
                Picker("Range", selection: $range) {
                    ForEach(RecapRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func label(_ status: WatcherStatus) -> String {
        switch status {
        case .watching: "Watching"
        case .paused: "Paused"
        case .stopped: "Stopped"
        case .down: "Watcher down"
        case .failing: store.watcher?.checkFailed != nil ? "GitHub check failed" : "Watcher error"
        }
    }

    private func color(_ status: WatcherStatus) -> Color {
        switch status {
        case .watching: .green
        case .paused: .yellow
        case .stopped: .gray
        case .down: .red
        case .failing: .orange
        }
    }
}

// MARK: Sections

struct SectionsView: View {
    let store: Store
    let now: Date

    var body: some View {
        let needs = store.needsYou
        let ready = store.readyToPost
        let active = store.inProgress
        let queued = store.queued
        let recent = store.recent
        VStack(alignment: .leading, spacing: 1) {
            if needs.isEmpty && ready.isEmpty && active.isEmpty && queued.isEmpty && recent.isEmpty {
                Text(store.entries.isEmpty ? "No review requests yet" : "No reviews in the last week")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            if !needs.isEmpty {
                SectionTitle("Needs you")
                ForEach(needs) { AttentionRow(store: store, item: $0) }
            }
            if !ready.isEmpty {
                SectionTitle("Ready to post")
                ForEach(ready) { ReadyRow(store: store, entry: $0, now: now) }
            }
            if !active.isEmpty {
                SectionTitle("In progress")
                ForEach(active) { RoundRow(store: store, entry: $0, now: now) }
            }
            if !queued.isEmpty {
                SectionTitle("Queued")
                ForEach(queued) { QueuedRow(store: store, entry: $0) }
            }
            if !recent.isEmpty {
                SectionTitle("Recent")
                ForEach(recent) { PostedRow(store: store, entry: $0, now: now) }
            }
        }
        .padding(.horizontal, 6)
    }
}

struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// "@author", with the repo's name when more than one repo is in the ledger.
@MainActor
private func byline(_ store: Store, _ e: Entry) -> [String] {
    var bits: [String] = []
    if store.multiRepo { bits.append(e.repoName) }
    if let author = e.author { bits.append("@" + author) }
    return bits
}

// MARK: Rows

struct AttentionRow: View {
    let store: Store
    let item: Attention

    var body: some View {
        let entry = store.entry(item.repo, item.pr)
        let reviewing = entry?.state == "reviewing"
        RowButton(help: reviewing ? "Show its tab in Rex" : "Show the watcher in Rex") {
            store.show(reviewing ? entry : nil)
        } content: {
            RowLayout(number: item.pr, title: entry?.title ?? item.repo, trailing: nil) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } detail: {
                Text(item.text).lineLimit(3)
            }
        }
        .contextMenu { LinkMenu(store: store, entry: entry) }
    }
}

struct ReadyRow: View {
    let store: Store
    let entry: Entry
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RowButton(help: "Show its tab in Rex") {
                store.show(entry)
            } content: {
                RowLayout(
                    number: entry.pr,
                    title: entry.title ?? "",
                    trailing: entry.startedAt?.isoDate.map { Format.short(since: $0, now: now) }
                ) {
                    Image(systemName: "checkmark.seal").foregroundStyle(.blue)
                } detail: {
                    Text((["Round \(entry.round ?? 1)", "checked, waiting for you"] + byline(store, entry)).joined(separator: " · "))
                }
            }
            HStack(spacing: 2) {
                FooterButton(title: "Post", symbol: "paperplane", busy: store.isPending("post:\(entry.id)"),
                             help: "Post the checked review from your account") { store.post(entry) }
                FooterButton(title: "Preview", symbol: "doc.text.magnifyingglass", busy: store.isPending("preview:\(entry.id)"),
                             help: "Open the review as it would post") { store.preview(entry) }
                FooterButton(title: "Dismiss", symbol: "xmark", busy: store.isPending("dismiss:\(entry.id)"),
                             help: "End the round without posting") { store.dismiss(entry) }
            }
            .padding(.leading, 30)
            .padding(.bottom, 4)
        }
        .contextMenu { LinkMenu(store: store, entry: entry, showTab: true) }
    }
}

struct RoundRow: View {
    let store: Store
    let entry: Entry
    let now: Date

    var body: some View {
        let blocked = store.roundStatus[entry.id]?.hasPrefix("BLOCKED") == true
        RowButton(help: "Show its tab in Rex") {
            store.show(entry)
        } content: {
            RowLayout(
                number: entry.pr,
                title: entry.title ?? "",
                trailing: entry.startedAt?.isoDate.map { Format.short(since: $0, now: now) }
            ) {
                if blocked {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                }
            } detail: {
                Text((["Round \(entry.round ?? 1)", store.phase(of: entry)] + byline(store, entry)).joined(separator: " · "))
            }
        }
        .contextMenu { LinkMenu(store: store, entry: entry, showTab: true) }
    }
}

struct QueuedRow: View {
    let store: Store
    let entry: Entry

    var body: some View {
        RowButton(help: "Open the PR on GitHub") {
            store.open(entry.url)
        } content: {
            RowLayout(number: entry.pr, title: entry.title ?? "", trailing: nil) {
                Image(systemName: "clock").foregroundStyle(.secondary)
            } detail: {
                Text(detail)
            }
        }
        .contextMenu { LinkMenu(store: store, entry: entry) }
    }

    private var detail: String {
        if let error = entry.startError { return "Didn't start: " + error }
        let waiting = store.state.paused == true
            ? "Paused"
            : (entry.trigger == "re-request" ? "Re-requested, waiting for a slot" : "Waiting for a slot")
        return ([waiting] + byline(store, entry)).joined(separator: " · ")
    }
}

struct PostedRow: View {
    let store: Store
    let entry: Entry
    let now: Date

    var body: some View {
        let verdict = Verdict(entry.verdict)
        RowButton(help: entry.isFinished ? "Merged or closed. Open the review on GitHub" : "Open the review on GitHub") {
            store.open(entry.reviewURL ?? entry.url)
        } content: {
            RowLayout(
                number: entry.pr,
                title: entry.title ?? "",
                trailing: entry.postedAt?.isoDate.map { Format.short(since: $0, now: now) },
                dimmed: entry.isFinished
            ) {
                Image(systemName: verdict.symbol).foregroundStyle(verdict.color)
            } detail: {
                HStack(spacing: 4) {
                    Text(verdict.label)
                    if let risk = entry.mergeRisk {
                        Text("·")
                        RiskBadge(risk: risk)
                    }
                    ForEach(byline(store, entry), id: \.self) { Text("· " + $0) }
                    if (entry.round ?? 1) > 1 {
                        Text("· round \(entry.round ?? 1)")
                    }
                }
                .lineLimit(1)
            }
        }
        .contextMenu { LinkMenu(store: store, entry: entry) }
    }
}

struct Verdict {
    let label: String
    let symbol: String
    let color: Color

    init(_ verdict: String?) {
        switch verdict {
        case "APPROVED": (label, symbol, color) = ("Approved", "checkmark.circle.fill", .green)
        case "CHANGES_REQUESTED": (label, symbol, color) = ("Changes requested", "xmark.circle.fill", .red)
        case "COMMENTED": (label, symbol, color) = ("Commented", "text.bubble.fill", .secondary)
        case "DISMISSED": (label, symbol, color) = ("Dismissed", "minus.circle", .secondary)
        default: (label, symbol, color) = ("Posted", "circle.fill", .secondary)
        }
    }
}

struct RiskBadge: View {
    let risk: String

    var body: some View {
        let color: Color = switch risk {
        case "low": .green
        case "medium": .orange
        case "high": .red
        default: .secondary
        }
        Text("\(risk) risk")
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct LinkMenu: View {
    let store: Store
    let entry: Entry?
    var showTab = false

    var body: some View {
        if let entry {
            if showTab {
                Button("Show Tab in Rex") { store.show(entry) }
            }
            Button("Open PR on GitHub") { store.open(entry.url) }
            if entry.reviewURL != nil {
                Button("Open Review on GitHub") { store.open(entry.reviewURL) }
            }
            Divider()
            Button("Copy PR Link") { store.copy(entry.url) }
        }
    }
}

// MARK: Row building blocks

/// A full-width row that highlights under the pointer, like a menu item.
struct RowButton<Content: View>: View {
    let help: String
    let action: () -> Void
    let content: Content
    @State private var hovering = false

    init(help: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.help = help
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct RowLayout<Icon: View, Detail: View>: View {
    let number: Int?
    let title: String
    let trailing: String?
    var dimmed = false
    @ViewBuilder let icon: Icon
    @ViewBuilder let detail: Detail

    init(
        number: Int?, title: String, trailing: String?, dimmed: Bool = false,
        @ViewBuilder icon: () -> Icon, @ViewBuilder detail: () -> Detail
    ) {
        self.number = number
        self.title = title
        self.trailing = trailing
        self.dimmed = dimmed
        self.icon = icon()
        self.detail = detail()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let number {
                        Text(verbatim: "#\(number)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let trailing {
                        Text(trailing)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(dimmed ? 0.6 : 1)
    }
}

// MARK: Footer

struct FooterView: View {
    let store: Store

    var body: some View {
        let status = store.watcherStatus
        let stopped = status == .stopped || status == .down
        let paused = store.state.paused == true
        HStack(spacing: 2) {
            FooterButton(
                title: paused ? "Resume" : "Pause",
                symbol: paused ? "play.circle" : "pause.circle",
                busy: store.isPending("pause"),
                help: paused ? "Start new rounds again" : "Finish current rounds, but start no new ones"
            ) { store.togglePause() }
            FooterButton(
                title: "Check now",
                symbol: "arrow.clockwise",
                busy: store.checkRequestedAt != nil,
                help: "Check GitHub for review requests now"
            ) { store.checkNow() }
            .disabled(stopped)
            FooterButton(
                title: stopped ? "Start" : "Stop",
                symbol: stopped ? "play.fill" : "stop.fill",
                busy: store.isPending("watcher"),
                help: stopped ? "Start the watcher" : "Stop the watcher. Open rounds carry on when it starts again"
            ) { store.toggleWatcher() }
            Spacer()
            Menu {
                Toggle("Open at Login", isOn: Binding(
                    get: { store.openAtLogin },
                    set: { store.setOpenAtLogin($0) }
                ))
                Button("Open State Folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Paths.stateDir))
                }
                Divider()
                Button("Quit Rex Reviewer") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}

struct FooterButton: View {
    let title: String
    let symbol: String
    let busy: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                }
                Text(title)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering && isEnabled ? Color.primary.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hovering = $0 }
        .help(help)
    }
}
