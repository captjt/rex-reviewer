import AppKit
import SwiftUI

/// `RexReviewer --snapshot out.png [--tab Recap] [--range "This week"]`
/// renders the panel to a PNG and quits, to check the layout without opening
/// the menu. REX_REVIEWER_STATE_DIR points it at sample data. --tab and
/// --range set the remembered choices, as clicking them would.
@MainActor
enum Snapshot {
    static func runIfAsked(_ store: Store) {
        let args = CommandLine.arguments
        // --print-recap "This week": print the recap's Markdown and quit.
        if let j = args.firstIndex(of: "--print-recap"), j + 1 < args.count, let range = RecapRange(rawValue: args[j + 1]) {
            print(store.recap(range).markdown(multiRepo: store.multiRepo))
            exit(0)
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        for (flag, key) in [("--tab", "panelTab"), ("--range", "recapRange")] {
            if let j = args.firstIndex(of: flag), j + 1 < args.count {
                UserDefaults.standard.set(args[j + 1], forKey: key)
            }
        }
        Task { @MainActor in
            let host = NSHostingView(rootView: PanelView(store: store).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<3 {
                try? await Task.sleep(for: .seconds(0.7))
                window.setContentSize(host.fittingSize)
            }
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            NSApp.terminate(nil)
        }
    }
}
