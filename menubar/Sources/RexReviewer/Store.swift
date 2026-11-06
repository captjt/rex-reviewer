import AppKit
import Observation
import ServiceManagement

/// rex-reviewer as its ledger describes it. It reloads when anything in the
/// state folder changes, and every 15 seconds for what lives elsewhere: each
/// round's .tmp/status.txt, and whether the watcher process is running.
@MainActor
@Observable
final class Store {
    private(set) var entries: [Entry] = []
    private(set) var state = PipelineState()
    private(set) var watcher: WatcherInfo?
    private(set) var roundStatus: [String: String] = [:]
    /// How PRs ended, from the merged and closed events, for entries that
    /// predate the outcome field.
    private(set) var endedEvents: [String: Ending] = [:]
    private(set) var watcherRunning = true
    private(set) var pending: Set<String> = []
    private(set) var checkRequestedAt: Date?
    private(set) var openAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var remoteControlOff = false
    /// rex-inbox's hub answers on its socket.
    private(set) var inboxRunning = false
    var badgeMode = BadgeMode(rawValue: UserDefaults.standard.string(forKey: "badgeMode") ?? "") ?? .automatic {
        didSet { UserDefaults.standard.set(badgeMode.rawValue, forKey: "badgeMode") }
    }
    var message: String?

    @ObservationIgnored private var streams: [FSEventStreamRef] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init() {
        // `RexReviewer --open-at-login on|off`: set the login item and quit.
        // `rex-reviewer app --login` uses it.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open-at-login"), i + 1 < args.count {
            do {
                if args[i + 1] == "off" {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
                print("open at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("open at login: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        reload()
        watch(Paths.stateDir)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkWatcherProcess()
                await self?.checkInbox()
                try? await Task.sleep(for: .seconds(15))
                self?.reload()
            }
        }
        Snapshot.runIfAsked(self)
    }

    // MARK: Reading

    func reload() {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        func load<T: Decodable>(_ path: String, as type: T.Type) -> T? {
            fm.contents(atPath: path).flatMap { try? decoder.decode(T.self, from: $0) }
        }

        // repos/<owner>/<name>/pr-<n>.json
        var list: [Entry] = []
        for owner in (try? fm.contentsOfDirectory(atPath: Paths.reposDir)) ?? [] {
            let ownerDir = Paths.reposDir + "/" + owner
            for name in (try? fm.contentsOfDirectory(atPath: ownerDir)) ?? [] {
                let repoDir = ownerDir + "/" + name
                for file in (try? fm.contentsOfDirectory(atPath: repoDir)) ?? []
                where file.hasPrefix("pr-") && file.hasSuffix(".json") {
                    if let e = load(repoDir + "/" + file, as: Entry.self) { list.append(e) }
                }
            }
        }
        list.sort { ($0.repo, $0.pr) < ($1.repo, $1.pr) }
        if list != entries { entries = list }

        let newState = load(Paths.stateDir + "/state.json", as: PipelineState.self) ?? PipelineState()
        if newState != state { state = newState }
        let newWatcher = load(Paths.stateDir + "/watcher.json", as: WatcherInfo.self)
        if newWatcher != watcher { watcher = newWatcher }

        struct Event: Decodable { let kind: String; let repo: String?; let pr: Int?; let at: String? }
        var ends: [String: Ending] = [:]
        if let data = fm.contents(atPath: Paths.stateDir + "/events.jsonl") {
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n")
            where line.contains("\"merged\"") || line.contains("\"closed\"") {
                guard let ev = try? decoder.decode(Event.self, from: Data(line.utf8)),
                      ev.kind == "merged" || ev.kind == "closed",
                      let repo = ev.repo, let pr = ev.pr, let at = ev.at?.isoDate else { continue }
                ends["\(repo)#\(pr)"] = Ending(outcome: ev.kind, at: at)
            }
        }
        if ends != endedEvents { endedEvents = ends }

        var status: [String: String] = [:]
        for e in list where e.state == "reviewing" {
            guard let wt = e.worktree,
                  let s = try? String(contentsOfFile: wt + "/.tmp/status.txt", encoding: .utf8) else { continue }
            status[e.id] = s.split(separator: "\n", maxSplits: 1).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        if status != roundStatus { roundStatus = status }

        if let asked = checkRequestedAt {
            let scanned = state.lastScanAt?.isoDate ?? .distantPast
            if scanned >= asked.addingTimeInterval(-1) || Date().timeIntervalSince(asked) > 30 {
                checkRequestedAt = nil
            }
        }
    }

    /// The watcher runs as `rex do <watch_script>`.
    func checkWatcherProcess() async {
        if Snapshot.isActive { return }
        guard let script = state.watchScript else {
            if watcherRunning { watcherRunning = false }
            return
        }
        // pgrep reads a regular expression; a path's dots match themselves too.
        let pattern = "rex do " + script
        let running = await Task.detached {
            Shell.run("/usr/bin/pgrep", ["-f", pattern]).status == 0
        }.value
        if running != watcherRunning { watcherRunning = running }
    }

    /// Whether rex-inbox's hub is running, from its socket.
    func checkInbox() async {
        if Snapshot.isActive { return }
        let path = Paths.inboxSocket
        let running = await Task.detached { Shell.socketAnswers(path) }.value
        if running != inboxRunning { inboxRunning = running }
    }

    /// Whether the icon turns orange for what needs you. rex-inbox shows the
    /// same items, from the watcher's status records, and can act on them,
    /// so by default it does the alerting while its hub runs.
    var badgesNeeds: Bool { badgeMode == .always || !inboxRunning }

    private func watch(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<Store>.fromOpaque(info).takeUnretainedValue()
            // The stream delivers on the main queue.
            MainActor.assumeIsolated { store.reload() }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        streams.append(stream)
    }

    // MARK: What the panel shows

    var watcherStatus: WatcherStatus {
        if state.stopped == true { return .stopped }
        if !watcherRunning { return .down }
        if state.paused == true { return .paused }
        if watcher?.checkFailed != nil || watcher?.error != nil { return .failing }
        return .watching
    }

    /// More than one repo in the ledger: rows name theirs.
    var multiRepo: Bool { Set(entries.map(\.repo)).count > 1 }

    /// What needs you, except reviews ready to post, which have their own section.
    var needsYou: [Attention] {
        (watcher?.attention ?? []).filter { $0.kind != "ready" }
    }

    var readyToPost: [Entry] {
        entries.filter { $0.state == "reviewing" && ($0.phase == "awaiting" || roundStatus[$0.id] == "AWAITING_APPROVAL") }
    }

    var inProgress: [Entry] {
        let ready = Set(readyToPost.map(\.id))
        return entries
            .filter { $0.state == "reviewing" && !ready.contains($0.id) }
            .sorted { ($0.startedAt ?? "") < ($1.startedAt ?? "") }
    }

    var queued: [Entry] {
        entries.filter { $0.state == "queued" }
    }

    /// Rounds that ended in the last week, newest first.
    var recent: [Entry] {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        return Array(
            entries
                .filter { $0.state != "reviewing" && $0.state != "queued" && ($0.postedAt?.isoDate ?? .distantPast) > cutoff }
                .sorted { ($0.postedAt ?? "") > ($1.postedAt ?? "") }
                .prefix(12)
        )
    }

    func ending(of e: Entry) -> Ending? {
        if let outcome = e.outcome, let at = e.endedAt?.isoDate {
            return Ending(outcome: outcome, at: at)
        }
        return endedEvents[e.id]
    }

    func recap(_ range: RecapRange, now: Date = Date()) -> Recap {
        Recap(range: range, entries: entries, endings: { self.ending(of: $0) }, now: now)
    }

    func entry(_ repo: String, _ pr: Int) -> Entry? {
        entries.first { $0.repo == repo && $0.pr == pr }
    }

    func phase(of e: Entry) -> String {
        let s = roundStatus[e.id] ?? ""
        if s.hasPrefix("BLOCKED") { return "Blocked" }
        if s.hasPrefix("POSTED") || s == "DISMISSED" { return "Done, closing its tab" }
        if s.hasPrefix("HEAD_MOVED") { return "New commits, the reviewers are catching up" }
        if e.phase == "checking" || s.hasPrefix("VERIFYING") { return "The checker is checking" }
        // With several reviewers, the primary's status is only its own.
        if let total = e.reviewersTotal, total > 1 {
            let done = e.reviewersDone ?? 0
            if done >= total { return "Reviewed, the checker is next" }
            return done == 0 ? "The \(total) reviewers are reviewing" : "\(done) of \(total) reviewers done"
        }
        if s == "READY_TO_POST" { return "Reviewed, the checker is next" }
        return "The reviewer is reviewing"
    }

    // MARK: Actions

    /// Run a rex-reviewer action with `rex do`, one at a time per key. Nil
    /// when it's already running or it failed; the failure goes to message.
    @discardableResult
    private func perform(_ key: String, _ arguments: [String]) async -> Shell.Result? {
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        message = nil
        let result = await Task.detached { Shell.rex(["do"] + arguments + ["--json"]) }.value
        pending.remove(key)
        if result.status != 0 { message = result.failure }
        reload()
        await checkWatcherProcess()
        return result.status == 0 ? result : nil
    }

    func isPending(_ key: String) -> Bool { pending.contains(key) }

    func togglePause() {
        let action = state.paused == true ? "reviewer_resume" : "reviewer_pause"
        Task { await perform("pause", [action]) }
    }

    func toggleWatcher() {
        let start = watcherStatus == .stopped || watcherStatus == .down
        Task { await perform("watcher", [start ? "reviewer_up" : "reviewer_down"]) }
    }

    /// The watcher checks GitHub within 5 seconds of this file appearing.
    func checkNow() {
        FileManager.default.createFile(atPath: Paths.checkNow, contents: nil)
        checkRequestedAt = Date()
    }

    func post(_ e: Entry) {
        Task { await perform("post:\(e.id)", ["reviewer_post"] + e.actionArgs) }
    }

    func dismiss(_ e: Entry) {
        Task { await perform("dismiss:\(e.id)", ["reviewer_dismiss"] + e.actionArgs) }
    }

    /// Render the review and open it in the default app for Markdown.
    func preview(_ e: Entry) {
        Task {
            guard let result = await perform("preview:\(e.id)", ["reviewer_preview"] + e.actionArgs) else { return }
            struct Preview: Decodable { let preview_path: String? }
            if let path = (try? JSONDecoder().decode(Preview.self, from: Data(result.output.utf8)))?.preview_path {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    /// Show a round's tab in Rex, or the watcher's with no entry. Rex
    /// switches tabs for another program only with Remote Control on;
    /// without it, the panel stays open and says so.
    func show(_ e: Entry?) {
        Task {
            guard let result = await perform("focus", ["reviewer_focus"] + (e?.actionArgs ?? [])) else { return }
            struct Focus: Decodable { let selected: Bool? }
            let focus = try? JSONDecoder().decode(Focus.self, from: Data(result.output.utf8))
            remoteControlOff = focus?.selected == false
            if !remoteControlOff {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.superlogical.rex").first?.activate()
            }
        }
    }

    func openRexServerSettings() {
        open("rex://settings/server")
    }

    func open(_ link: String?) {
        guard let link, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func copy(_ link: String?) {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    // MARK: Login item

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = error.localizedDescription
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
