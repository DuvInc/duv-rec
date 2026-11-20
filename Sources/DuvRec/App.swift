import AppKit
import AVFoundation
import SwiftUI

/* An app you open yourself, with its controls in its window: no global shortcut, on purpose
   (one less thing to collide with the app being recorded). During a take there is NO window
   at all: the settings window hides, and the take is driven from the menu bar item (a red dot
   and the time), whose menu has Pause or Resume, Stop, and Restart. The item exists
   only during a take; the window comes back when the take ends. */
@main
struct DuvRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var rec = Recorder.shared

    private var taking: Binding<Bool> {
        Binding(get: { rec.state == .recording || rec.state == .stopping }, set: { _ in })
    }

    var body: some Scene {
        Window("Duv Rec", id: "main") {
            RootView().environmentObject(rec)
        }
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: taking) {
            if rec.state == .stopping {
                Text("Saving files…")
            } else {
                if rec.paused {
                    Button("Resume") { rec.resume() }
                } else {
                    Button("Pause") { rec.pause() }
                }
                Button("Stop") { rec.stop() }
                Divider()
                Button("Restart from zero") { rec.restart() }
            }
            if let p = rec.problem {
                Divider()
                Text(p)
            }
        } label: {
            Image(nsImage: rec.paused ? pauseMark : recordDot)
            Text(clock(rec.elapsed)).monospacedDigit()
        }
    }
}

struct RootView: View {
    @EnvironmentObject var rec: Recorder
    private var taking: Bool { rec.state == .recording || rec.state == .stopping }

    var body: some View {
        MainView()
            .onChange(of: taking) { _, now in if now || !rec.restarting { showMainWindow(!now) } }
    }
}

/// A red dot that stays red in the menu bar (a template image would be drawn black or white).
private let recordDot: NSImage = {
    let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    img.isTemplate = false
    return img
}()

/// Two orange bars: the take is on hold.
private let pauseMark: NSImage = {
    let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
        NSColor.systemOrange.setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 1, width: 3, height: 10), xRadius: 1, yRadius: 1).fill()
        NSBezierPath(roundedRect: NSRect(x: 7, y: 1, width: 3, height: 10), xRadius: 1, yRadius: 1).fill()
        return true
    }
    img.isTemplate = false
    return img
}()

/// Hidden for the whole take, back in front when it ends. Hidden is not closed: the app keeps running.
func showMainWindow(_ show: Bool) {
    for w in NSApp.windows where w.identifier?.rawValue == "main" {
        if show {
            // Back on screen without taking the focus: after a take, the Finder shows its folder in front.
            w.orderFront(nil)
        } else {
            w.orderOut(nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window quits, but not during a take: the window is hidden then, which macOS
    /// also counts as "last window closed", and quitting there ended the take as it began.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Recorder.shared.state == .idle && !Recorder.shared.restarting
    }

    /// Never quit in the middle of a take: stop it first, the files are closed properly.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch Recorder.shared.state {
        case .idle: return .terminateNow
        case .recording:
            Recorder.shared.stop { NSApp.terminate(nil) }
            return .terminateCancel
        default: return .terminateCancel
        }
    }
}

func clock(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

struct CameraPreview: NSViewRepresentable {
    let layer: CALayer
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.layer = layer
        view.wantsLayer = true
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Peak level, −60 to 0 dBFS. The green band is where a voice should peak.
struct LevelMeter: View {
    let level: Float
    let peak: Float
    private func x(_ db: Float, _ w: CGFloat) -> CGFloat { w * CGFloat((max(-60, min(0, db)) + 60) / 60) }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                Rectangle().fill(Color.green.opacity(0.18)).frame(width: x(-6, w) - x(-18, w)).offset(x: x(-18, w))
                RoundedRectangle(cornerRadius: 3).fill(level > -3 ? Color.red : Color.accentColor).frame(width: x(level, w))
                Rectangle().fill(peak > -3 ? Color.red : Color.primary).frame(width: 2).offset(x: max(0, x(peak, w) - 2))
            }
        }
        .frame(height: 10)
    }
}

enum Source: Hashable { case screen, camera, sound }

/// One source: tap to see its settings, the round button turns it on or off.
struct SourceTile: View {
    let icon: String
    let title: String
    let detail: String
    let on: Bool
    let selected: Bool
    let toggle: () -> Void
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).font(.system(size: 18, weight: .medium))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                Spacer()
                Button(action: toggle) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(on ? "Turn off" : "Turn on")
            }
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(on ? detail : "Off").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: select)
    }
}

struct MainView: View {
    @EnvironmentObject var rec: Recorder
    @State private var source = Source.screen

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !rec.screenAccess && rec.settings.screenOn { accessBox }

            HStack(spacing: 8) {
                SourceTile(icon: "display", title: "Screen", detail: screenDetail, on: rec.settings.screenOn,
                           selected: source == .screen, toggle: { rec.settings.screenOn.toggle(); source = .screen }, select: { source = .screen })
                SourceTile(icon: "web.camera", title: "Camera", detail: cameraDetail, on: rec.settings.cameraOn,
                           selected: source == .camera, toggle: { rec.settings.cameraOn.toggle(); source = .camera }, select: { source = .camera })
                SourceTile(icon: "mic", title: "Sound", detail: soundDetail, on: rec.settings.micOn || rec.settings.systemAudio,
                           selected: source == .sound, toggle: toggleSound, select: { source = .sound })
            }

            Group {
                switch source {
                case .screen: screenPanel
                case .camera: cameraPanel
                case .sound: soundPanel
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))

            footer
        }
        .padding(16)
        .frame(width: 480)
        .onAppear { rec.refreshDisplays(); rec.updateFreeSpace() }
    }

    // MARK: Tiles

    private var displayName: String {
        rec.displays.first { $0.id == rec.settings.displayID }?.name ?? "Main display"
    }

    private var screenDetail: String {
        if rec.settings.screenMode == .region { return rec.regionPixels.map { "Area \($0)" } ?? "Area not selected" }
        return rec.displays.count > 1 ? displayName : "Full screen"
    }

    private var cameraDetail: String {
        let name = rec.cameras.first { $0.id == rec.settings.cameraID }?.name ?? "No camera"
        return "\(name) · \(rec.settings.camera4K ? "4K" : "1080p")"
    }

    private var soundDetail: String {
        let mic = rec.mics.first { $0.id == rec.settings.micID }?.name ?? "Microphone"
        switch (rec.settings.micOn, rec.settings.systemAudio) {
        case (true, true): return "\(mic) + Mac"
        case (true, false): return mic
        default: return "Mac audio"
        }
    }

    private func toggleSound() {
        let on = rec.settings.micOn || rec.settings.systemAudio
        rec.settings.micOn = !on
        if on { rec.settings.systemAudio = false }
        source = .sound
    }

    // MARK: Panels

    private var screenPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $rec.settings.screenMode) {
                Text("Full screen").tag(ScreenMode.display)
                Text("Area").tag(ScreenMode.region)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if rec.settings.screenMode == .display {
                if rec.displays.count > 1 {
                    Picker("Display", selection: $rec.settings.displayID) {
                        ForEach(rec.displays) { Text($0.name).tag($0.id) }
                    }
                }
                Toggle("Hide menu bar", isOn: $rec.settings.hideMenuBar)
            } else {
                HStack {
                    Button(rec.settings.region == nil ? "Select area…" : "Change area…") { rec.drawRegion() }
                    if let px = rec.regionPixels {
                        let where_ = rec.displays.count > 1 ? (rec.displays.first { $0.id == rec.settings.regionDisplayID }?.name ?? "") : ""
                        Text([px, where_].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }

            HStack(spacing: 16) {
                Toggle("Cursor", isOn: $rec.settings.showCursor)
                if #available(macOS 15.0, *) { Toggle("Show clicks", isOn: $rec.settings.showClicks) }
                Spacer()
                Picker("", selection: $rec.settings.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }
        }
        .disabled(!rec.settings.screenOn)
        .opacity(rec.settings.screenOn ? 1 : 0.5)
    }

    private var cameraPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            CameraPreview(layer: rec.rig.previewLayer)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    if !rec.cameraInfo.isEmpty {
                        Text(rec.cameraInfo).font(.caption2).monospacedDigit().padding(4)
                            .background(.black.opacity(0.5)).foregroundStyle(.white).padding(6)
                    }
                }
                .opacity(rec.settings.cameraOn ? 1 : 0.3)
            HStack {
                Picker("", selection: Binding(get: { rec.settings.cameraID }, set: { rec.chooseCamera($0) })) {
                    ForEach(rec.cameras) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                Picker("", selection: $rec.settings.camera4K) {
                    Text("4K").tag(true)
                    Text("1080p").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }
        }
        .disabled(!rec.settings.cameraOn)
    }

    private var soundPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $rec.settings.micOn) {
                Picker("Microphone", selection: Binding(get: { rec.settings.micID }, set: { rec.chooseMic($0) })) {
                    ForEach(rec.mics) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(!rec.settings.micOn)
            }
            if rec.settings.micOn {
                HStack {
                    LevelMeter(level: rec.micLevel, peak: rec.micPeak)
                    Text(rec.micPeak > -100 ? String(format: "%.0f dB", rec.micPeak) : "–")
                        .font(.caption).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Toggle("Mac audio (separate track)", isOn: $rec.settings.systemAudio)
        }
    }

    private var accessBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Duv Rec cannot record the screen yet", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.orange)
            HStack {
                Button("Open System Settings") { rec.openScreenSettings() }
                Button("Relaunch Duv Rec") { rec.relaunch() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { chooseFolder() } label: {
                    Label((rec.settings.folder as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.link)
                Spacer()
                Text(String(format: "%.0f GB free", rec.freeGB)).font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $rec.settings.quality) {
                    ForEach(Quality.allCases) { Text("\($0.label) quality").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .font(.callout)

            if let p = rec.problem {
                Text(p).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: rec.toggle) {
                Label(rec.state == .starting ? "Starting…" : "Start recording", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(rec.state != .idle || !rec.hasSource)

            if let f = rec.lastFolder {
                Button("Show last take in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: rec.settings.folder)
        if panel.runModal() == .OK, let url = panel.url { rec.settings.folder = url.path }
    }
}
