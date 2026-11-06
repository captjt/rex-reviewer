import AppKit
import SwiftUI

// The menu bar app for rex-reviewer. It reads the ledger in
// ~/.local/state/rex-reviewer (see docs/ledger.md) and runs rex-reviewer's
// own Rex actions.

@main
struct RexReviewerApp: App {
    @State private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar item: an icon for the watcher's state, and a count.
struct MenuBarLabel: View {
    let store: Store

    var body: some View {
        let (image, count) = badge
        HStack(spacing: 2) {
            Image(nsImage: image)
            if let count {
                Text(verbatim: "\(count)")
            }
        }
    }

    /// Orange when something needs you; otherwise the system's own color.
    /// While rex-inbox alerts you to what needs you (Store.badgesNeeds), only
    /// a watcher that's down turns it orange: with no watcher, there are no
    /// status records for rex-inbox to see.
    private var badge: (NSImage, Int?) {
        let active = store.inProgress.count
        let activeCount = active > 0 ? active : nil
        switch store.watcherStatus {
        case .stopped:
            return (.symbol("stop.circle"), nil)
        case .down:
            return (.symbol("exclamationmark.triangle.fill", color: .systemOrange), nil)
        default:
            break
        }
        let needs = store.needsYou.count + store.readyToPost.count
        if needs > 0 && store.badgesNeeds {
            return (.symbol("exclamationmark.circle.fill", color: .systemOrange), needs)
        }
        switch store.watcherStatus {
        case .paused:
            return (.symbol("pause.circle"), activeCount)
        case .failing:
            return (.symbol("exclamationmark.triangle"), activeCount)
        default:
            return (.symbol("arrow.triangle.pull"), activeCount)
        }
    }
}

extension NSImage {
    /// An SF Symbol for the menu bar: a template image the system tints, or
    /// a colored one.
    static func symbol(_ name: String, color: NSColor? = nil) -> NSImage {
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let color {
            config = config.applying(.init(paletteColors: [color]))
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Rex Reviewer")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = color == nil
        return image
    }
}
