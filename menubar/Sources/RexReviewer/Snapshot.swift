import AppKit
import SwiftUI

/// `RexReviewer --snapshot out.png [--tab Recap] [--range "This week"] [--appearance light]`
/// renders the panel to a PNG at 2x and quits, to check the layout without
/// opening the menu. REX_REVIEWER_STATE_DIR points it at sample data. --tab and
/// --range set the remembered choices, as clicking them would. menubar/screenshots.sh
/// renders the README's screenshots this way.
@MainActor
enum Snapshot {
    /// Sample data has no watcher process, so a snapshot doesn't look for one.
    static let isActive = CommandLine.arguments.contains("--snapshot")

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
            if let j = args.firstIndex(of: "--appearance"), j + 1 < args.count {
                window.appearance = NSAppearance(named: args[j + 1] == "light" ? .aqua : .darkAqua)
            }
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<3 {
                try? await Task.sleep(for: .seconds(0.7))
                window.setContentSize(host.fittingSize)
            }
            // The window is off screen, so its backing scale is 1. Draw at 2x
            // so the PNG stays sharp on a Retina display.
            let size = host.bounds.size
            if let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) {
                rep.size = size
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            NSApp.terminate(nil)
        }
    }
}
