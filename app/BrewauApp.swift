import AppKit
import SwiftUI

@main struct BrewauApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        MenuBarExtra {
            UpdatePopover(model: model)
        } label: {
            Label {
                Text("brewau")
            } icon: {
                Image(nsImage: menuBarIcon(updates: model.hasScanned && !model.availableUpdates.isEmpty, busy: model.busy))
            }
        }.menuBarExtraStyle(.window)
        Settings {
            SettingsView(model: model)
        }.windowResizability(.contentSize)
    }
}

/// Template version of the brewau mark (small cut): a badge when updates are waiting,
/// faded bubbles while a scan or upgrade runs.
func menuBarIcon(updates: Bool, busy: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
        let transform = NSAffineTransform()
        transform.scale(by: rect.width / 256)
        transform.concat()
        let ring = NSBezierPath(roundedRect: NSRect(x: 16, y: 16, width: 224, height: 224), xRadius: 68, yRadius: 68)
        ring.append(NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 160, height: 160), xRadius: 36, yRadius: 36))
        ring.windingRule = .evenOdd
        NSColor.black.setFill()
        ring.fill()
        NSColor.black.withAlphaComponent(busy ? 0.4 : 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 88, y: 64, width: 64, height: 64)).fill()
        NSBezierPath(ovalIn: NSRect(x: 125, y: 143, width: 42, height: 42)).fill()
        if updates {
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 160, y: -24, width: 120, height: 120)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 184, y: 0, width: 72, height: 72)).fill()
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = updates ? "brewau, opdateringer tilgængelige" : "brewau"
    return image
}
