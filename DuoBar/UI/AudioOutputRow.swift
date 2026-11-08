import AppKit
import SwiftUI

struct AudioOutputRow: View {
    let symbol: String
    let title: String
    let detail: String
    let stateText: String
    let outputs: [AudioDeviceStatus]
    let selectedUID: String?
    let onSelect: (String) -> Bool
    let onOpenSoundSettings: () -> Void
    let onOpenBluetoothSettings: () -> Void
    var emptyText = localized("No output devices")
    var failureText = localized("Unable to Switch Output")
    var hint = localized("Select audio output")
    var showsBluetoothSettings = true
    /// False when the row shares a card with the volume slider.
    var showsCard = true
    @State private var switchFailed = false

    var body: some View {
        // DuoBar+: SwiftUI's Menu collapses a custom label to icon and title
        // on macOS, which hid the selected device. The row is drawn as a
        // regular StatusRow and an AppKit layer on top opens the same menu.
        CompactRowLabel(symbol: symbol, title: title, trailing: detail)
        .allowsHitTesting(false)
        .popoverRowCard(showsCard)
        .overlay {
            PopUpMenuArea(makeMenu: makeMenu)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        if outputs.isEmpty {
            menu.addItem(PopUpMenuArea.disabledItem(emptyText))
        } else {
            for device in outputs {
                let uid = device.uid
                let item = PopUpMenuArea.item(device.name) { [selectedUID] in
                    guard uid != selectedUID else { return }
                    switchFailed = !onSelect(uid)
                }
                item.state = device.uid == selectedUID ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(PopUpMenuArea.item(localized("Sound Settings…"), action: onOpenSoundSettings))
        if showsBluetoothSettings {
            menu.addItem(PopUpMenuArea.item(localized("Bluetooth Settings…"), action: onOpenBluetoothSettings))
        }
        if switchFailed {
            menu.addItem(PopUpMenuArea.disabledItem(failureText))
        }
        return menu
    }
}

/// A transparent area that opens an `NSMenu` below itself on click.
struct PopUpMenuArea: NSViewRepresentable {
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> PopUpMenuView {
        let view = PopUpMenuView()
        view.makeMenu = makeMenu
        return view
    }

    func updateNSView(_ view: PopUpMenuView, context: Context) {
        view.makeMenu = makeMenu
    }

    static func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureMenuTarget(action: action)
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.invoke), keyEquivalent: "")
        item.target = target
        item.representedObject = target // the item keeps its target alive
        return item
    }

    static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

final class PopUpMenuView: NSView {
    var makeMenu: (() -> NSMenu)?

    override func mouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.minY - 4), in: self)
    }
}

final class ClosureMenuTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}
