import SwiftUI
import AppKit
import ApplicationServices
import Combine
import UniformTypeIdentifiers

struct WorkSegment: Codable, Identifiable {
    var id = UUID()
    var appID: String
    var appName: String
    var windowTitle: String
    var started: Date
    var ended: Date
    var seconds: TimeInterval
}

final class TimeStore: ObservableObject {
    @Published private(set) var segments: [WorkSegment] = []
    private let url: URL
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Worktime", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("activity.json")
        if let data = try? Data(contentsOf: url), let items = try? JSONDecoder().decode([WorkSegment].self, from: data) { segments = items }
    }
    func append(appID: String, appName: String, title: String, from: Date, to: Date, seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let cal = Calendar.current
        // Split at local midnight so daily totals stay correct.
        var cursor = from
        while cursor < to {
            let midnight = cal.nextDate(after: cursor, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) ?? to
            let end = min(midnight, to)
            let part = end.timeIntervalSince(cursor)
            if part <= 0 { break }
            let key = appID + "\u{1f}" + title
            if let index = segments.indices.last, segments[index].appID + "\u{1f}" + segments[index].windowTitle == key, abs(segments[index].ended.timeIntervalSince(cursor)) < 1.1 {
                segments[index].ended = end
                segments[index].seconds += part
            } else {
                segments.append(WorkSegment(appID: appID, appName: appName, windowTitle: title, started: cursor, ended: end, seconds: part))
            }
            cursor = end
        }
        persist()
    }
    func total(on date: Date) -> TimeInterval { segments.filter { Calendar.current.isDate($0.started, inSameDayAs: date) }.reduce(0) { $0 + $1.seconds } }
    func apps(on date: Date) -> [(String, TimeInterval)] {
        let filtered = segments.filter { Calendar.current.isDate($0.started, inSameDayAs: date) }
        return Dictionary(grouping: filtered, by: { $0.appName }).map { ($0.key, $0.value.reduce(0) { $0 + $1.seconds }) }.sorted { $0.1 > $1.1 }
    }
    func windows(on date: Date) -> [(String, TimeInterval)] {
        let filtered = segments.filter { Calendar.current.isDate($0.started, inSameDayAs: date) }
        return Dictionary(grouping: filtered, by: { "\($0.appName) — \($0.windowTitle)" }).map { ($0.key, $0.value.reduce(0) { $0 + $1.seconds }) }.sorted { $0.1 > $1.1 }
    }
    func exportCSV() -> URL? {
        let head = "app_id,app,window,start,end,seconds\n"
        func q(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows = segments.map { [q($0.appID), q($0.appName), q($0.windowTitle), q(ISO8601DateFormatter().string(from: $0.started)), q(ISO8601DateFormatter().string(from: $0.ended)), String(format: "%.1f", $0.seconds)].joined(separator: ",") }.joined(separator: "\n")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("worktime-export.csv")
        return (try? (head + rows).write(to: out, atomically: true, encoding: .utf8)) == nil ? out : nil
    }
    private func persist() { if let data = try? JSONEncoder().encode(segments) { try? data.write(to: url, options: .atomic) } }
}

final class Tracker: ObservableObject {
    @Published var enabled = true { didSet { UserDefaults.standard.set(enabled, forKey: "trackingEnabled") } }
    @Published var idleLimit: Double = 60 { didSet { UserDefaults.standard.set(idleLimit, forKey: "idleLimit") } }
    @Published private(set) var isIdle = false
    @Published private(set) var currentApp = "—"
    @Published private(set) var today: TimeInterval = 0
    @Published private(set) var accessibility = AXIsProcessTrusted()
    let store = TimeStore()
    private var timer: Timer?
    private var previous: Date?
    private var previousIdentity: (id: String, name: String, title: String)?
    init() {
        if UserDefaults.standard.object(forKey: "trackingEnabled") != nil { enabled = UserDefaults.standard.bool(forKey: "trackingEnabled") }
        if UserDefaults.standard.object(forKey: "idleLimit") != nil { idleLimit = UserDefaults.standard.double(forKey: "idleLimit") }
        today = store.total(on: Date())
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }
    @objc private func sleep() { previous = nil; isIdle = true }
    @objc private func wake() { previous = nil; isIdle = false }
    func requestAccessibility() { let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary; _ = AXIsProcessTrustedWithOptions(options); accessibility = AXIsProcessTrusted() }
    private func identity() -> (id: String, name: String, title: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ("unknown", "Unknown", "Untitled window") }
        let name = app.localizedName ?? "Unknown"
        let id = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        var title = "Untitled window"
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success, let window {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success, let string = value as? String, !string.isEmpty { title = string }
            }
        }
        return (id, name, title)
    }
    private func idleSeconds() -> Double {
        let keyboard = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let mouseMove = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let left = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        let right = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDown)
        let scroll = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel)
        return min(keyboard, mouseMove, left, right, scroll)
    }
    private func tick() {
        let now = Date()
        let active = identity()
        let idle = idleSeconds()
        isIdle = idle >= idleLimit
        currentApp = active.name
        accessibility = AXIsProcessTrusted()
        defer { previous = now; previousIdentity = active; today = store.total(on: now) }
        guard enabled, let previous, let old = previousIdentity else { return }
        let elapsed = now.timeIntervalSince(previous)
        guard elapsed > 0, elapsed < 5 else { return } // no counting during sleep or clock jumps
        // Attribute each elapsed interval to the previously observed foreground window.
        // Retain the allowed portion of an idle interval, then stop until new input.
        let valid = min(elapsed, max(0, idleLimit - max(0, idle - elapsed)))
        guard valid > 0 else { return }
        store.append(appID: old.id, appName: old.name, title: old.title, from: previous, to: previous.addingTimeInterval(valid), seconds: valid)
    }
}

func duration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}

struct FloatingView: View {
    @ObservedObject var tracker: Tracker
    var openReport: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button { tracker.enabled.toggle() } label: {
                Circle().fill(tracker.enabled ? (tracker.isIdle ? Color.orange : Color.green) : Color.gray).frame(width: 8, height: 8).frame(width: 24, height: 24)
            }.buttonStyle(.plain).help(tracker.enabled ? "Stop tracking" : "Start tracking")
            Button(action: openReport) {
                Text(duration(tracker.today)).font(.system(size: 12, weight: .medium)).monospacedDigit().contentTransition(.numericText())
            }.buttonStyle(.plain).help("Open activity report")
        }
        .padding(.leading, 4).padding(.trailing, 13).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }
}

final class FloatingPanel: NSPanel {
    init(tracker: Tracker, openReport: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 220, y: 650, width: 145, height: 36), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true; level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        isMovableByWindowBackground = true; hidesOnDeactivate = false
        contentView = NSHostingView(rootView: FloatingView(tracker: tracker, openReport: openReport).padding(2))
    }
    override var canBecomeKey: Bool { true }
}

struct ReportView: View {
    @ObservedObject var tracker: Tracker
    @State private var selectedDate = Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Worktime").font(.title2.bold()); Spacer(); DatePicker("Date", selection: $selectedDate, displayedComponents: .date).labelsHidden() }
            Text(duration(tracker.store.total(on: selectedDate))).font(.system(size: 32, weight: .semibold)).monospacedDigit()
            Text("Active time · applications").foregroundStyle(.secondary)
            let apps = tracker.store.apps(on: selectedDate)
            if apps.isEmpty { ContentUnavailableView("No activity yet", systemImage: "clock") }
            ForEach(apps, id: \.0) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(item.0); Spacer(); Text(duration(item.1)).monospacedDigit().foregroundStyle(.secondary) }
                    GeometryReader { geo in Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: max(2, geo.size.width * item.1 / max(1, apps.first?.1 ?? 1)), height: 6) }.frame(height: 6)
                }
            }
            Divider()
            Text("Windows").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(tracker.store.windows(on: selectedDate), id: \.0) { item in
                        HStack { Text(item.0).lineLimit(1); Spacer(); Text(duration(item.1)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
            }
            HStack {
                Button("Export CSV") {
                    guard let url = tracker.store.exportCSV() else { return }
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "worktime.csv"; panel.allowedContentTypes = [.commaSeparatedText]
                    if panel.runModal() == .OK, let target = panel.url { try? FileManager.default.removeItem(at: target); try? FileManager.default.copyItem(at: url, to: target) }
                }
                Spacer()
                Text("Stored locally").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(22).frame(minWidth: 520, minHeight: 470)
    }
}

struct MenuContent: View {
    @ObservedObject var tracker: Tracker
    @Binding var showFloat: Bool
    var toggleFloating: () -> Void
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Today: \(duration(tracker.today))")
        Text(tracker.enabled ? (tracker.isIdle ? "Idle" : "Recording · \(tracker.currentApp)") : "Stopped")
        Divider()
        Button(tracker.enabled ? "Stop tracking" : "Start tracking") { tracker.enabled.toggle() }
        Button(showFloat ? "Hide floating timer" : "Show floating timer") { toggleFloating() }
        Button("Activity report…") { openWindow(id: "report") }
        if !tracker.accessibility { Button("Allow window titles…") { tracker.requestAccessibility() } }
        Divider()
        Button("Quit Worktime") { NSApplication.shared.terminate(nil) }
    }
}

@main struct WorktimeApp: App {
    @StateObject private var tracker = Tracker()
    @State private var panel: FloatingPanel?
    @State private var showFloat = true
    @State private var reportWindow: NSWindow?
    var body: some Scene {
        MenuBarExtra {
            MenuContent(tracker: tracker, showFloat: $showFloat, toggleFloating: toggleFloating)
                .onAppear { ensurePanel() }
        } label: {
            Label(duration(tracker.today), systemImage: tracker.enabled ? "circle.fill" : "circle")
        }
        Window("Activity Report", id: "report") { ReportView(tracker: tracker) }
            .defaultSize(width: 600, height: 550)
        Settings {
            Form {
                Toggle("Tracking enabled", isOn: $tracker.enabled)
                Picker("Idle threshold", selection: $tracker.idleLimit) { Text("30 seconds").tag(30.0); Text("60 seconds").tag(60.0); Text("120 seconds").tag(120.0); Text("180 seconds").tag(180.0) }
                Button("Request Accessibility permission") { tracker.requestAccessibility() }
            }.padding().frame(width: 370)
        }
    }
    private func toggleFloating() {
        showFloat.toggle()
        ensurePanel()
        if showFloat { panel?.orderFront(nil) } else { panel?.orderOut(nil) }
    }
    private func showReport() {
        if reportWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 550),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Activity Report"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ReportView(tracker: tracker))
            reportWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        reportWindow?.makeKeyAndOrderFront(nil)
    }
    private func ensurePanel() {
        guard panel == nil else { return }
        let p = FloatingPanel(tracker: tracker, openReport: showReport)
        panel = p
        if showFloat { p.orderFront(nil) }
    }
}
