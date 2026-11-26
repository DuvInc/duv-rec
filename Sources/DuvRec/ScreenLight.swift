import AppKit

/// A second display turned into a fill light: plain neutral white at full brightness, borderless,
/// above everything on that display. Neutral white gave the least orange skin of the colours
/// compared in a real take. Never on the recorded display (it would cover what you record, even
/// though this app's windows are excluded from the capture). A click on the white turns it off.
final class ScreenLight: ObservableObject {
    static let shared = ScreenLight()

    @Published private(set) var display: CGDirectDisplayID?
    private var window: NSWindow?
    private var screenChanges: Any?

    var isOn: Bool { display != nil }

    /// The display to light: any display but the recorded one, an external one first.
    static func target(avoiding recorded: CGDirectDisplayID?) -> NSScreen? {
        let others = NSScreen.screens.filter { displayID(of: $0) != recorded && CGDisplayIsInMirrorSet(displayID(of: $0)) == 0 }
        return others.first { CGDisplayIsBuiltin(displayID(of: $0)) == 0 } ?? others.first
    }

    func toggle(avoiding recorded: CGDirectDisplayID?) {
        isOn ? turnOff() : turnOn(avoiding: recorded)
    }

    func turnOn(avoiding recorded: CGDirectDisplayID?) {
        guard let screen = Self.target(avoiding: recorded) else { return turnOff() }
        let w = window ?? makeWindow()
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        display = displayID(of: screen)
        if screenChanges == nil {
            // A display unplugged or rearranged: follow it, or go off if it is gone.
            screenChanges = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, let id = self.display else { return }
                if let s = NSScreen.screens.first(where: { displayID(of: $0) == id }) {
                    self.window?.setFrame(s.frame, display: true)
                } else {
                    self.turnOff()
                }
            }
        }
    }

    /// Called when the recorded display changes: the light never stays on top of it.
    func avoid(_ recorded: CGDirectDisplayID?) {
        if let id = display, id == recorded { turnOn(avoiding: recorded) }
    }

    func turnOff() {
        window?.orderOut(nil)
        display = nil
        if let o = screenChanges { NotificationCenter.default.removeObserver(o) }
        screenChanges = nil
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .white
        w.colorSpace = .sRGB
        w.level = .screenSaver
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.contentView = LightView { [weak self] in self?.turnOff() }
        window = w
        return w
    }
}

/// Hides the pointer over the white (a pointer in the middle of the light shows in the glasses)
/// and turns the light off on a click.
private final class LightView: NSView {
    private let off: () -> Void
    private static let noCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    init(off: @escaping () -> Void) {
        self.off = off
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // activeAlways: the light is never the key window, and cursor rects only work in one.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { Self.noCursor.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { off() }
}
