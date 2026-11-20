import AppKit

func displayID(of screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

/// A zone is kept in the display's own points, origin top-left: what ScreenCaptureKit's sourceRect takes.
func globalFrame(of region: CGRect, on screen: NSScreen) -> NSRect {
    NSRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY, width: region.width, height: region.height)
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draw the zone to record, Screen Studio style: every screen is dimmed except the zone; drag
/// anywhere to draw it, drag inside to move it, drag a corner or an edge to resize it.
/// Return or "Valider" keeps it, Escape or "Cancel" leaves the previous one.
final class RegionPicker {
    private static var current: RegionPicker?
    private var windows: [NSWindow] = []
    fileprivate var views: [RegionView] = []
    private var keyMonitor: Any?
    private let done: ((CGDirectDisplayID, CGRect)?) -> Void

    static func pick(display: CGDirectDisplayID, region: CGRect?, done: @escaping ((CGDirectDisplayID, CGRect)?) -> Void) {
        current?.finish(nil)
        let picker = RegionPicker(done: done)
        current = picker
        picker.show(display: display, region: region)
    }

    private init(done: @escaping ((CGDirectDisplayID, CGRect)?) -> Void) { self.done = done }

    private func show(display: CGDirectDisplayID, region: CGRect?) {
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Explicitly false: by default macOS lets clicks through the transparent parts of a
            // window, and the zone itself is transparent, so dragging it clicked the app beneath.
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            let v = RegionView(frame: NSRect(origin: .zero, size: screen.frame.size), display: displayID(of: screen), picker: self)
            if displayID(of: screen) == display, let region {
                v.rect = NSRect(x: region.minX, y: screen.frame.height - region.maxY, width: region.width, height: region.height)
            }
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w)
            views.append(v)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Escape and Return work whichever screen's overlay has the keyboard.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: self.finish(nil); return nil            // Escape
            case 36, 76: self.confirm(); return nil          // Return, Enter
            default: return nil                              // nothing else while picking
            }
        }
        let start = views.first { $0.rect != nil } ?? views.first
        start?.window?.makeKey()
        start?.window?.makeFirstResponder(start)
        views.forEach { $0.layoutBar() }
    }

    fileprivate func began(on view: RegionView) {
        for v in views where v !== view && v.rect != nil {
            v.rect = nil
            v.layoutBar()
            v.needsDisplay = true
        }
    }

    fileprivate func confirm() {
        guard let v = views.first(where: { $0.rect != nil }), let r = v.rect else { return }
        finish((v.display, CGRect(x: r.minX, y: v.bounds.height - r.maxY, width: r.width, height: r.height)))
    }

    fileprivate func finish(_ result: (CGDirectDisplayID, CGRect)?) {
        guard RegionPicker.current === self else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        views = []
        RegionPicker.current = nil
        done(result)
    }
}

private struct Edges: OptionSet {
    let rawValue: Int
    static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
}

private final class RegionView: NSView {
    var rect: NSRect?
    let display: CGDirectDisplayID
    private weak var picker: RegionPicker?
    private enum Drag { case draw(NSPoint), move(NSPoint, NSRect), resize(Edges, NSPoint, NSRect) }
    private var drag: Drag?
    private let bar = NSStackView()
    private static let minSide: CGFloat = 120

    init(frame: NSRect, display: CGDirectDisplayID, picker: RegionPicker) {
        self.display = display
        self.picker = picker
        super.init(frame: frame)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "Use this area", target: self, action: #selector(confirm))
        ok.keyEquivalent = "\r"
        ok.bezelColor = .controlAccentColor
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.addArrangedSubview(cancel)
        bar.addArrangedSubview(ok)
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if let r = rect { addCursorRect(r.insetBy(dx: 12, dy: 12), cursor: .openHand) }
    }

    @objc private func cancel() { picker?.finish(nil) }
    @objc private func confirm() { picker?.confirm() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancel()                 // Escape
        case 36, 76: confirm()            // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    func layoutBar() {
        guard let r = rect else { bar.isHidden = true; return }
        bar.isHidden = false
        let size = bar.fittingSize
        var y = r.minY - size.height - 12
        if y < 8 { y = r.minY + 12 }
        let x = min(max(8, r.midX - size.width / 2), bounds.width - size.width - 8)
        bar.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func handles(_ r: NSRect) -> [(Edges, NSPoint)] {
        [([.left, .bottom], NSPoint(x: r.minX, y: r.minY)), ([.right, .bottom], NSPoint(x: r.maxX, y: r.minY)),
         ([.left, .top], NSPoint(x: r.minX, y: r.maxY)), ([.right, .top], NSPoint(x: r.maxX, y: r.maxY)),
         ([.left], NSPoint(x: r.minX, y: r.midY)), ([.right], NSPoint(x: r.maxX, y: r.midY)),
         ([.bottom], NSPoint(x: r.midX, y: r.minY)), ([.top], NSPoint(x: r.midX, y: r.maxY))]
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let r = rect { dim.appendRect(r); dim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()

        if let r = rect {
            // Never fully transparent: a fully clear pixel can still pass a click through on some setups.
            NSColor.white.withAlphaComponent(0.01).setFill()
            r.fill(using: .sourceOver)
        }
        guard let r = rect else {
            label("Drag to select the area to record · Esc to cancel", at: NSPoint(x: bounds.midX, y: bounds.midY), centered: true)
            return
        }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1.5
        border.stroke()
        for (_, p) in handles(r) {
            let h = NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: h).fill()
            NSColor.black.withAlphaComponent(0.4).setStroke()
            NSBezierPath(ovalIn: h).stroke()
        }
        let scale = window?.backingScaleFactor ?? 2
        let size = "\(Int((r.width * scale).rounded()) & ~1) × \(Int((r.height * scale).rounded()) & ~1)"
        label(size, at: NSPoint(x: r.minX + 8, y: min(r.maxY + 8, bounds.height - 28)), centered: false)
    }

    private func label(_ text: String, at p: NSPoint, centered: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let origin = centered ? NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2) : p
        let pill = NSRect(x: origin.x - 8, y: origin.y - 4, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        s.draw(at: origin)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        picker?.began(on: self)
        window?.makeKey()
        window?.makeFirstResponder(self)
        if let r = rect, let hit = handles(r).first(where: { hypot($0.1.x - p.x, $0.1.y - p.y) < 12 }) {
            drag = .resize(hit.0, p, r)
        } else if let r = rect, r.contains(p) {
            drag = .move(p, r)
        } else {
            drag = .draw(p)
            rect = nil
        }
        bar.isHidden = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let q = NSPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
        switch drag {
        case .draw(let a):
            rect = NSRect(x: min(a.x, q.x), y: min(a.y, q.y), width: abs(q.x - a.x), height: abs(q.y - a.y))
        case .move(let a, let r):
            var n = r.offsetBy(dx: p.x - a.x, dy: p.y - a.y)
            n.origin.x = min(max(0, n.minX), bounds.width - n.width)
            n.origin.y = min(max(0, n.minY), bounds.height - n.height)
            rect = n
        case .resize(let edges, let a, let r):
            var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
            let dx = q.x - a.x, dy = q.y - a.y
            if edges.contains(.left) { minX = min(r.minX + dx, maxX - Self.minSide) }
            if edges.contains(.right) { maxX = max(r.maxX + dx, minX + Self.minSide) }
            if edges.contains(.bottom) { minY = min(r.minY + dy, maxY - Self.minSide) }
            if edges.contains(.top) { maxY = max(r.maxY + dy, minY + Self.minSide) }
            rect = NSRect(x: max(0, minX), y: max(0, minY), width: min(bounds.width, maxX) - max(0, minX), height: min(bounds.height, maxY) - max(0, minY))
        case nil:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        window?.invalidateCursorRects(for: self)
        if let r = rect, r.width < Self.minSide || r.height < Self.minSide { rect = nil }
        layoutBar()
        needsDisplay = true
    }
}

/// A thin red frame around the zone while it records. It sits just outside the zone, and this
/// app's windows are never captured anyway.
final class RegionBorder {
    private var window: NSWindow?

    func show(region: CGRect, display: CGDirectDisplayID) {
        hide()
        guard let screen = NSScreen.screens.first(where: { displayID(of: $0) == display }) else { return }
        let frame = globalFrame(of: region, on: screen).insetBy(dx: -3, dy: -3)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = .floating
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        v.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        v.layer?.borderWidth = 2
        v.layer?.cornerRadius = 3
        w.contentView = v
        w.orderFrontRegardless()
        window = w
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}
