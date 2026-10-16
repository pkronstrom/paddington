import AppKit
import ApplicationServices
import ServiceManagement
import Foundation
import PaddingtonCore
@_silgen_name("sandbox_check") func sandbox_check(_ pid: pid_t, _ operation: UnsafePointer<CChar>?, _ type: Int32) -> Int32

/// The running app: wires MIDI, Bluetooth, context, engine, executor, agent state and UI together.
public final class AppController: NSObject, NSApplicationDelegate {
    var config: Config?
    var engine: Engine?
    var decoder: DeviceDecoder?
    var lastError: String?
    let midi = MIDIService()
    var ble: BLEMIDIConnector?
    let executor = Executor()
    let server = ControlServer()
    let agents = AgentStore()
    var custom: [String: Value] = [:]
    var context = Context()
    var clientTTY: String?
    var lastRegularApp: NSRunningApplication?
    var previousApp: RunningApp?
    var searchOpen = false     // the search box belongs to the open search picker
    var screenChoices: ScreenChoices?   // a choice prompt on the focused agent's screen
    let dictation = DictationWatcher()
    let drums = DrumSidecar()
    var midiNote: Int?        // the note of the MIDI message being handled (nil for simulate/socket input)
    var lastPanesAt = Date.distantPast
    var tmuxFailing = false
    var lastContextLog = ""
    let legend = LegendController()
    let sounds = SoundPlayer()
    let leds = PadLEDs()
    let inputWindow = InputWindow()
    var statusItem: NSStatusItem!
    var paused = false
    var configStamp: Date?
    var lastPadMessage: Date?
    /// [sleep]: lights dark after a while without pad input (saves the pad's battery); the next press only wakes it.
    var padSleep = PadSleep(after: 300, now: Date().timeIntervalSince1970)
    var wantedYou: Set<String> = []     // agents waiting for you at the last render ([sleep] wake_for_agents)
    var timers: [Timer] = []
    var lastUnmappedToast = Date.distantPast

    var now: Double { Date().timeIntervalSince1970 }
    /// PADDINGTON_TEST=1: no permission prompts, no Bluetooth, no iTerm scripting; PADDINGTON_FAKE_APP overrides the frontmost app.
    let testMode = ProcessInfo.processInfo.environment["PADDINGTON_TEST"] == "1"
    let fakeApp = ProcessInfo.processInfo.environment["PADDINGTON_FAKE_APP"]

    public override init() { super.init() }

    /// Started from an agent's sandboxed shell (Codex …)? Then tmux sockets and more are off limits.
    static let sandboxed: Bool = sandbox_check(getpid(), nil, 0) != 0

    /// Leave a sandbox by having launchd (the login agent) or LaunchServices start a fresh copy, then quit.
    func escapeSandbox() -> Bool {
        let job = "gui/\(getuid())/\(Self.agentLabel)"
        let viaAgent = Shell.run(["launchctl", "print", job]).ok && Shell.run(["launchctl", "kickstart", job]).ok
        let ok = viaAgent || Shell.run(["open", "-n", Bundle.main.bundlePath]).ok
        Log.write("started inside a sandbox: relaunch \(ok ? "requested" : "failed") (\(viaAgent ? "launchd" : "open"))")
        return ok
    }

    public func applicationDidFinishLaunching(_ n: Notification) {
        // a write to a closed socket or pipe must be an error, never a silent kill (SIGPIPE leaves no crash report)
        signal(SIGPIPE, SIG_IGN)
        // a shell's tmux variables say nothing about the user's focus; don't let child tmux commands use them
        unsetenv("TMUX"); unsetenv("TMUX_PANE")
        if Self.sandboxed, !testMode, escapeSandbox() { exit(0) }
        legend.headless = testMode
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusIcon(connected: false, text: "")
        if !testMode {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }

        reloadConfig(initial: true)
        DispatchQueue.global(qos: .utility).async { _ = PickerDef.vaultSkills(); _ = PickerDef.firefoxTopSites() }   // warm the lists
        PickerDef.providers["windows"] = { WindowList.items() }
        Log.write("start pid=\(getpid()) launchd=\(ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == Self.agentLabel)")
        migrateLoginItem()
        executor.onToast = { [weak self] in self?.legend.toast($0) }
        executor.onError = { [weak self] in if let s = self?.config?.settings { self?.sounds.play("error", settings: s) } }
        executor.onState = { [weak self] k, v in self?.setState(k, v) }
        executor.clientTTY = { [weak self] in self?.clientTTY }

        server.handler = { [weak self] req in self?.handle(req) ?? ["ok": false] }
        do { try server.start() } catch let e as AlreadyRunning {
            Log.write("exit: \(e)")
            FileHandle.standardError.write(Data("paddington: \(e)\n".utf8))
            exit(0)
        } catch { lastError = "socket: \(error)" }

        midi.onMessage = { [weak self] m, src in self?.midiMessage(m, source: src) }
        midi.onSetupChanged = { [weak self] in
            guard let self else { return }
            // pad gone while a key is held (Talk): release it so nothing stays stuck
            if !self.padSourcePresent, let e = self.engine, e.holdingKeys { self.process(e.releaseAll()) }
            self.ensureConnection(); self.render()
        }
        do { try midi.start() } catch { lastError = "MIDI: \(error.localizedDescription)" }
        leds.onGlobal = { [weak self] g in self?.padGlobal(g) }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshContext(); self?.render()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // after sleep: reconnect the pad and its lights right away
            for delay in [1.0, 4.0, 10.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.ensureConnection(); self?.render() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            if let e = self?.engine { self?.process(e.releaseAll()) }
        }
        timers = [
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() },
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshContext(); self?.render() },
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkConfigChanged(); self?.checkApprovals(); self?.checkSleep(); self?.checkUpdated() },
            Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.reconcile(); self?.ensureConnection() },
        ]
        refreshContext()
        ensureConnection()
        render()
        legend.showBriefly(3)
    }

    public func applicationWillTerminate(_ n: Notification) {
        engine.map { process($0.releaseAll()) }
        server.stop()
    }

    // MARK: config

    func configFilesStamp() -> Date? {
        let root = Config.defaultRoot
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])?.allObjects as? [URL] ?? []
        return files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    func checkConfigChanged() {
        let s = configFilesStamp()
        if s != configStamp { reloadConfig(initial: false) }
    }

    @discardableResult
    func reloadConfig(initial: Bool) -> String? {
        configStamp = configFilesStamp()
        do {
            let c = try Config.load()
            config = c
            padSleep.after = c.settings.sleepAfter
            if let e = engine { e.reload(c) } else { engine = Engine(config: c) }
            if decoder?.profile.name != c.device.name || decoder == nil || !initial { decoder = DeviceDecoder(profile: c.device) }
            legend.position = c.settings.legendPosition
            let scale = CGFloat(max(0.5, min(2, c.settings.legendScale)))
            legend.model.scale = scale; legend.pickerModel.scale = scale
            legend.pinSeconds = c.settings.legendPinSeconds
            lastError = nil
            if ble == nil { ble = BLEMIDIConnector(nameMatch: c.device.match) } else { ble?.nameMatch = c.device.match }
            ble?.onStatus = { [weak self] _ in self?.render() }
            if !initial { legend.toast(c.warnings.isEmpty ? "Config reloaded" : "Config reloaded · \(c.warnings.count) warning(s)") }
            render()
            return nil
        } catch {
            lastError = "\(error)"
            legend.toast("Config error — keeping the last good config")
            render()
            return lastError
        }
    }

    // MARK: connection

    var padSourcePresent: Bool {
        guard let m = config?.device.match else { return false }
        return MIDIService.sources().contains { $0.online && (m.isEmpty || $0.name.localizedCaseInsensitiveContains(m)) }
    }

    func ensureConnection() {
        midi.refresh()
        if testMode { return }
        if let s = config?.settings, s.ledMode != "off", padSourcePresent,
           ["off", "pad not connected", "LEDs disconnected"].contains(leds.status) { leds.start() }
        if padSourcePresent { ble?.stop() } else { ble?.connect() }
    }

    // MARK: context

    func refreshContext() {
        var c = Context()
        if let fake = fakeApp {
            c.app = fake; c.appName = fake
            c.windowTitle = ProcessInfo.processInfo.environment["PADDINGTON_FAKE_TITLE"] ?? ""
        } else if let front = NSWorkspace.shared.frontmostApplication {
            // alerts, permission prompts and overlay helpers (accessory apps) don't count: keep the last regular app
            if front.activationPolicy == .regular || lastRegularApp?.isTerminated != false { lastRegularApp = front }
            let app = lastRegularApp ?? front
            c.app = app.bundleIdentifier ?? ""
            c.appName = app.localizedName ?? ""
            c.windowTitle = Self.focusedWindowTitle(pid: app.processIdentifier)
            c.fullscreen = Self.focusedWindowFullscreen(pid: app.processIdentifier)
        }
        c.running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
            RunningApp(bundleId: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "",
                       file: $0.bundleURL?.deletingPathExtension().lastPathComponent ?? "")
        }
        // the app in front before this one (app = "previous"), while it still runs
        if !c.app.isEmpty, c.app != context.app, let old = context.running.first(where: { $0.bundleId == context.app }) { previousApp = old }
        c.previousApp = c.running.first { $0.bundleId == previousApp?.bundleId && $0.bundleId != c.app }
        // a failing tmux call (busy machine, timeout) keeps the last good pane list for 10 s instead of falling to Default
        do {
            c.panes = Tmux.available ? try Tmux.panesOrError() : []
            lastPanesAt = Date()
            if tmuxFailing { tmuxFailing = false; Log.write("tmux ok again") }
        } catch {
            if !tmuxFailing {
                tmuxFailing = true; Log.write("\(error)")
                if Self.sandboxed { lastError = "Paddington was started inside a sandbox and can't reach tmux — quit it and start it again from Spotlight or `paddington start` in a normal terminal" }
                else { legend.toast("tmux: \(error)") }
            }
            c.panes = Date().timeIntervalSince(lastPanesAt) < 10 ? context.panes : []
        }
        if c.app == ITerm.bundleId {
            clientTTY = testMode ? nil : ITerm.focusedTTYCached()
            c.focusedPane = Tmux.focusedPane(tty: clientTTY, panes: c.panes)
        } else {
            c.focusedPane = nil
        }
        if let p = c.focusedPane { agents.visit(pane: p.paneId, now: now) }
        // a choice prompt on the focused agent's screen (questions, permission menus — Claude and Codex)
        if let p = c.focusedPane, Snapshot.agentCommands.contains(p.command), !testMode {
            let r = Tmux.run(["capture-pane", "-p", "-t", p.paneId])
            let found = r.ok ? ScreenChoices.parse(r.out) : nil
            if found != screenChoices {
                if let f = found { Log.write("choices on screen in \(p.paneId): \(f.options.map { "\($0.key). \($0.label)" }.joined(separator: " | "))") }
                screenChoices = found
                render()
            }
        } else if screenChoices != nil { screenChoices = nil }
        let changed = c != context
        context = c
        if changed, let e = engine {
            process(e.contextChanged(c))
            if !e.lastEvent.isEmpty { Log.write(e.lastEvent); e.lastEvent = "" }
        }
        let sig = "app=\(c.app) tty=\(clientTTY ?? "-") pane=\(c.focusedPane.map { "\($0.paneId) (\($0.command))" } ?? "-") panes=\(c.panes.count)\(c.fullscreen ? " fullscreen" : "") layer=\(engine?.layerPath(c, now: now) ?? "-")"
        if sig != lastContextLog {
            lastContextLog = sig
            // iTerm in front but no pane: say which tmux clients there were, to see why
            let why = c.app == ITerm.bundleId && c.focusedPane == nil && !testMode
                ? " clients=[\(Tmux.clients().map { "\($0.tty) \($0.session)" }.joined(separator: ", "))]" : ""
            Log.write("context \(sig)\(why)")
        }
    }

    static func focusedWindowTitle(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win else { return "" }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String ?? ""
    }

    /// The front window fills its screen: macOS fullscreen (AXFullScreen, Chrome's fullscreen videos) or a window
    /// sized to the whole screen (Firefox's fullscreen videos, with the menu bar hidden).
    static func focusedWindowFullscreen(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
        guard let w = attr(app, kAXFocusedWindowAttribute) else { return false }
        let win = w as! AXUIElement
        if (attr(win, "AXFullScreen") as? Bool) == true { return true }
        var pos = CGPoint.zero, size = CGSize.zero
        guard let p = attr(win, kAXPositionAttribute), let s = attr(win, kAXSizeAttribute) else { return false }
        AXValueGetValue(p as! AXValue, .cgPoint, &pos); AXValueGetValue(s as! AXValue, .cgSize, &size)
        // AX frames are top-left based; a screen's full frame starts at its top edge too
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.contains { sc in
            let top = primaryH - sc.frame.maxY
            return abs(pos.x - sc.frame.minX) < 2 && abs(pos.y - top) < 2 && abs(size.width - sc.frame.width) < 2 && abs(size.height - sc.frame.height) < 2
        }
    }

    /// The installed executable's inode at launch; scripts/build-app.sh swaps in a new bundle without restarting us.
    let launchedInode = AppController.executableInode()
    static func executableInode() -> UInt64? {
        guard let p = Bundle.main.executablePath, Bundle.main.bundleURL.pathExtension == "app",
              let a = try? FileManager.default.attributesOfItem(atPath: p) else { return nil }
        return (a[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// A new version is installed: relaunch through launchd (login agent) or LaunchServices, so the new
    /// process starts clean no matter who ran the build (an agent's sandboxed shell can't give it tmux).
    func checkUpdated() {
        guard !testMode, let old = launchedInode, let cur = Self.executableInode(), cur != old else { return }
        Log.write("new version installed: relaunching")
        if let e = engine { process(e.releaseAll()) }
        drums.stop()
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == Self.agentLabel { exit(75) }   // launchd restarts us
        _ = Shell.spawn(["/bin/sh", "-c", "sleep 1; /usr/bin/open '\(Bundle.main.bundlePath)'"])
        NSApp.terminate(nil)
    }

    /// Every second: a permission request counts as "approve?" only once its prompt is on the agent's screen
    /// (Codex's Guardian approves most requests itself without one), and stops when the prompt goes away.
    func checkApprovals() {
        guard !testMode else { return }
        var changed = false
        for a in agents.approvalRequests {
            let r = Tmux.run(["capture-pane", "-p", "-t", a.pane])
            guard r.ok, AgentStore.approvalShown(r.out) else { continue }
            Log.write("approval prompt on screen in \(a.pane) (\(a.approvalAsked ?? ""))")
            changed = agents.showApproval(session: a.sessionId, now: now) || changed
        }
        for a in agents.approvalWaits(now: now) {
            let r = Tmux.run(["capture-pane", "-p", "-t", a.pane])
            guard r.ok, !AgentStore.approvalStillShown(r.out) else { continue }
            Log.write("approval prompt gone in \(a.pane) (\(a.reason)) → working")
            changed = agents.dismissApproval(session: a.sessionId, now: now) || changed
        }
        if changed { render() }
    }

    func reconcile() {
        if agents.reconcile(panes: context.panes, agentCommands: Snapshot.agentCommands) { render() }
    }

    func snapshot() -> Snapshot {
        var s = Snapshot.build(context: context, agents: agents, custom: custom, layerPath: engine?.layerPath(context, now: now) ?? "")
        // what's on screen wins over the hook payload: it has Claude's own extra options ("Type something") too
        if let sc = screenChoices { for (k, v) in sc.vars { s.values[k] = v } }
        s.values["sounds.agents"] = .bool(agentSounds)
        return s
    }

    // MARK: input

    func midiMessage(_ m: MIDIMessage, source: String) {
        guard let cfg = config, let dec = decoder, !paused else { return }
        // a test instance must not act on the real pad too (every press would run twice); PADDINGTON_TEST_MIDI=1 allows it
        if testMode, ProcessInfo.processInfo.environment["PADDINGTON_TEST_MIDI"] != "1" { return }
        guard cfg.device.match.isEmpty || source.localizedCaseInsensitiveContains(cfg.device.match) else { return }
        lastPadMessage = Date()
        let events = dec.decode(m)
        if events.isEmpty {
            if m.isNoteOn || (m.isCC && m.data2 > 0), Date().timeIntervalSince(lastUnmappedToast) > 3 {
                lastUnmappedToast = Date()
                legend.toast("Unmapped: \(m.description) — run `paddington learn`")
            }
            return
        }
        if let e = engine, e.padBank != dec.padBank { e.padBank = dec.padBank }
        if let e = engine, e.knobBank != dec.knobBank { e.knobBank = dec.knobBank }
        let (left, woke) = padSleep.input(events, now: now)
        if woke { Log.write("pad awake (\(events.map(\.control).joined(separator: " ")))"); render(); return }
        midiNote = m.isNoteOn ? Int(m.data1) : nil
        defer { midiNote = nil }
        for ev in left { input(ev) }
    }

    /// Every second: the pad falls asleep after [sleep] after without input.
    func checkSleep() {
        guard !testMode || ProcessInfo.processInfo.environment["PADDINGTON_TEST_SLEEP"] == "1" else { return }
        if padSleep.check(now: now) { Log.write("pad asleep (\(Int(padSleep.after)) s without input)"); render() }
    }

    /// The pad's global settings changed (read twice a second with the lights' session): it reports its pad bank
    /// there, so the bank is known at once instead of from the next pad press.
    func padGlobal(_ g: [UInt8]) {
        guard g.count == PadLEDs.Global.size else { return }
        let bank = g[PadLEDs.Global.padBank] == 0 ? "A" : "B"
        decoder?.setPadBank(bank)
        engine?.padBankLive = true
        if let e = engine, e.padBank != bank { e.padBank = bank; Log.write("pad bank \(bank) (as the pad reports it)"); render() }
    }

    /// Which global byte, if any, drives the side-button / BT lights: each byte whose meaning is unknown (or the
    /// ones given) gets a test value for a few seconds (watch the pad), then its own value back. Logged; everything is
    /// restored at the end.
    var probing = false
    func probeSideLights(bytes: [Int] = [3, 6, 9, 1, 4, 5, 7], hold: Double = 4) -> [String: Any] {
        guard !probing else { return ["ok": false, "error": "a test is already running"] }
        guard leds.ready, leds.global.count == PadLEDs.Global.size else { return ["ok": false, "error": "the pad's light session isn't up (\(leds.status))"] }
        probing = true
        let original = leds.global
        let steps: [(Int, UInt8)] = bytes.filter { (0..<PadLEDs.Global.size).contains($0) }.map { ($0, original[$0] == 0 ? 1 : 0) }
        Log.write("side-light test: start, global \(PadLEDs.hex(original))")
        var t = 1.0
        for (n, (i, v)) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self else { return }
                Log.write("side-light test \(n + 1)/\(steps.count): byte \(i) \(String(format: "%02X", original[i])) → \(String(format: "%02X", v))")
                self.leds.writeGlobal(index: i, value: v)
                self.legend.toast("Pad test \(n + 1) of \(steps.count) (byte \(i)) — did any light change?")
            }
            t += hold
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.leds.writeGlobal(index: i, value: original[i]) }
            t += 1.5
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 1) { [weak self] in
            guard let self else { return }
            self.probing = false
            let now = self.leds.global
            if now == original { Log.write("side-light test: done, global as before"); self.legend.toast("Side-light test done") }
            else {
                Log.write("side-light test: done, global \(PadLEDs.hex(now)) differs from \(PadLEDs.hex(original)) — writing it back")
                for i in 0..<min(now.count, original.count) where now[i] != original[i] { self.leds.writeGlobal(index: i, value: original[i]) }
                self.legend.toast("Side-light test done (restored the pad's settings)")
            }
        }
        return ["ok": true, "steps": steps.count, "seconds": Int(t + 1)]
    }

    @objc func sleepNow() {
        padSleep.sleep()
        Log.write("pad asleep (menu)")
        render()
    }

    func input(_ ev: ControlEvent) {
        guard let e = engine else { return }
        if talkInput(ev) { return }
        // while the text window is open, ▶ submits and ⏸ cancels; ● (talk) keeps working for dictation
        if inputWindow.isOpen {
            if case .down("play") = ev { inputWindow.submit(); return }
            if case .down("pause") = ev { inputWindow.cancel(); return }
            if case .up(let c) = ev, c == "play" || c == "pause" { return }
        }
        if case .down = ev { refreshContext() }
        switch ev {
        case .down(let c): legend.model.pressed.insert(c)
        case .up(let c): legend.model.pressed.remove(c)
        case .turn(let c, _):
            legend.model.pressed.insert(c)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.legend.model.pressed.remove(c) }
        }
        process(e.handle(ev, now: now, ctx: context, snap: snapshot()))
        render()
    }

    func tick() {
        guard let e = engine else { return }
        let out = e.tick(now: now, ctx: context, snap: snapshot())
        if !out.isEmpty { process(out); render() }
    }

    /// A search picker: the list overlay gets a search row at the top that takes typing (without taking focus
    /// from the terminal) and dictation (VoiceInk's transcript or new clipboard text). A dictated phrase takes the
    /// clear best match by itself; Enter / ▶ takes the highlighted item (the top match from the search row).
    func openSearch() {
        guard !testMode, let e = engine, let p = e.picker, p.searching else { return }
        if let s = config?.settings { sounds.play("picker", settings: s) }
        var pending: DispatchWorkItem?
        searchOpen = true
        Log.write("search: open \(p.id) (talk held: \(e.isHeld("rec")))")
        func finish(take: Bool) {
            guard let e = engine, searchOpen else { return }
            pending?.cancel()
            Log.write("search: \(take ? "take \(e.picker.map { $0.items.isEmpty ? "-" : $0.items[max(0, $0.index)].label } ?? "-")" : "cancel")")
            refreshContext()
            process(take ? e.commitPicker(now: now, ctx: context, snap: snapshot()) : e.cancelPicker())
            render()
        }
        legend.beginSearch(onType: { [weak self] text, added in
            guard let self, let e = self.engine, self.searchOpen else { return }
            Log.write("search: text “\(text)” (+\(added))")
            self.process(e.filterPicker(text, now: self.now))
            self.render()
            // a dictated phrase (or paste) arrives at once: when it settles, take the match if it's clearly the one
            pending?.cancel()
            guard added >= 3 else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, let e = self.engine, self.searchOpen, let pick = e.confidentPick() else { return }
                Log.write("search “\(text)” → \(pick.label)")
                finish(take: true)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }, onSubmit: { finish(take: true) }, onCancel: { finish(take: false) })
        dictation.start { [weak self] text in self?.legend.setSearchText(text) }
    }

    // MARK: hands-free dictation

    /// VoiceInk on ●: a hold is push-to-talk; a quick tap starts hands-free and the next tap stops it (pastes).
    /// While hands-free is on, ▶ stops it, waits until the text is in, then presses Enter.
    var talkDownAt = 0.0, lastTalkTap = -10.0
    var talkLatched = false { didSet { if talkLatched && !oldValue { latchTranscript = DictationWatcher.latestTranscript()?.id ?? 0 } } }
    var latchTranscript: Int64 = 0      // newest transcript when hands-free started: a newer one means it already ended
    var talkUpTranscript: Int64 = 0     // newest transcript when ● was let go: VoiceInk's text for that comes after it
    var swallowPlayUp = false
    var injectingPlay = false           // the ▶ paddington presses itself once the text is in: never caught again here

    /// A finished VoiceInk transcript newer than `id` (VoiceInk saves each recording once it's transcribed).
    func transcriptDone(after id: Int64) -> (id: Int64, text: String)? {
        guard let t = DictationWatcher.latestTranscript(), t.id > id, t.done else { return nil }
        return (t.id, t.text)
    }

    /// Returns true when the event was used up here.
    func talkInput(_ ev: ControlEvent) -> Bool {
        let talk = config?.settings.roles["talk"] ?? "rec"
        switch ev {
        case .down(let c) where c == talk:
            talkDownAt = now
            talkHandled = false                 // a new recording: its ▶ may wait for the text again
        case .up(let c) where c == talk:
            let held = now - talkDownAt
            talkUpTranscript = DictationWatcher.latestTranscript()?.id ?? 0
            if held >= 0.35 { talkLatched = false }      // push-to-talk: VoiceInk stops on release
            else { talkLatched.toggle() }                // a tap starts or stops hands-free
            Log.write("talk: ● \(held >= 0.35 ? "hold" : "tap") \(String(format: "%.2f", held))s → hands-free \(talkLatched ? "on" : "off") (recorder on screen: \(DictationWatcher.recorderVisible()))")
        case .down("play") where engine?.picker == nil && !inputWindow.isOpen && !injectingPlay:
            if talkLatched, let t = transcriptDone(after: latchTranscript) {
                Log.write("talk: hands-free already ended (VoiceInk saved “\(t.text)”) — ▶ is just Enter")
                talkLatched = false
            }
            if talkLatched {
                talkLatched = false; swallowPlayUp = true
                stopTalkThenEnter(tapToStop: true, after: DictationWatcher.latestTranscript()?.id ?? 0)
                return true
            }
            // ● was just let go and VoiceInk hasn't saved that recording's text yet: wait for it, then Enter.
            // (Not "is the recorder window up" — newer VoiceInk keeps a window on screen all the time.)
            if now - talkDownAt < 15, talkDownAt > 0, transcriptDone(after: talkUpTranscript) == nil, !talkHandled {
                swallowPlayUp = true
                stopTalkThenEnter(tapToStop: false, after: talkUpTranscript)
                return true
            }
        case .up("play") where swallowPlayUp && !injectingPlay:
            swallowPlayUp = false
            return true
        default: break
        }
        return false
    }

    /// Hands-free dictation for a free-form answer: after the option is picked, tap the talk key (VoiceInk starts);
    /// ● again pastes, ▶ pastes and sends.
    func startDictation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            let talkKey = (try? KeyChord.parse("rightcmd")) ?? KeyChord(modifiers: [], key: "rightcmd")
            try? Keyboard.down(talkKey); usleep(40_000); try? Keyboard.up(talkKey)
            self.talkLatched = true
            Log.write("talk: free-form answer — dictation started (● pastes, ▶ pastes and sends)")
            self.legend.toast("🎤 Speak — ● to paste · ▶ to paste and send")
        }
    }

    /// The ▶ after dictation already waited for (or got) its text: a later ▶ is a plain Enter again.
    var talkHandled = false

    func stopTalkThenEnter(tapToStop: Bool, after before: Int64) {
        let talkKey = (try? KeyChord.parse("rightcmd")) ?? KeyChord(modifiers: [], key: "rightcmd")
        Log.write("talk: ▶ — \(tapToStop ? "stop hands-free, " : "")wait for the text, then Enter")
        if tapToStop { try? Keyboard.down(talkKey); usleep(40_000); try? Keyboard.up(talkKey) }     // the stop tap VoiceInk expects
        talkHandled = true
        let started = Date()
        func poll() {
            if let t = transcriptDone(after: before) {
                // the transcript is saved; give the paste a moment, then Enter through the normal ▶ binding —
                // pressed as paddington's own ▶, so this code doesn't catch it again
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self else { return }
                    Log.write("talk: “\(t.text)” is in — Enter")
                    self.injectingPlay = true
                    self.input(.down("play")); self.input(.up("play"))
                    self.injectingPlay = false
                }
                return
            }
            guard Date().timeIntervalSince(started) < 12 else {
                legend.toast("No dictation arrived — not pressing Enter"); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }

    func process(_ outs: [EngineOutput]) {
        for o in outs {
            switch o {
            case .plan(let p):
                // a drum hit from the pad was already played by padbeat (it listens to the MIDI itself)
                // only notes padbeat has acknowledged for the current map; otherwise paddington plays it itself
                let byPadbeat = midiNote.map { drums.plays($0) } ?? false
                if let s = config?.settings, !(byPadbeat && p.steps.isEmpty) { sounds.play(p.sound, settings: s) }
                if !p.steps.isEmpty { executor.run(p) }
            case .legend(let cmd): legend.apply(cmd)
            case .search: openSearch()
            case .dictate: startDictation()
            case .input(let r):
                if testMode { break }
                if let s = config?.settings { sounds.play("picker", settings: s) }
                inputWindow.open(prompt: r.prompt) { [weak self] text in
                    guard let self, let e = self.engine else { return }
                    guard let text else { if let s = self.config?.settings { self.sounds.play("cancel", settings: s) }; return }
                    self.refreshContext()
                    self.process(e.submitInput(r, text: text, now: self.now, ctx: self.context, snap: self.snapshot()))
                }
            case .redraw: break
            }
        }
    }

    func setState(_ k: String, _ v: Value) {
        if k == "@agent.reset", let p = v.string { agents.reset(pane: p, now: now) }
        else if k == "@sounds.agents" { toggleAgentSounds() }
        else if v.isNull { custom[k] = nil } else { custom[k] = v }
        render()
    }

    // MARK: rendering

    func render() {
        guard let cfg = config, let e = engine else {
            setStatusIcon(connected: padSourcePresent, text: "!")
            rebuildMenu()
            return
        }
        playAgentSounds(cfg.settings)
        let snap = snapshot()
        // the search picker ended elsewhere (a pad chose, ⏸, timeout): close its search box too
        if searchOpen, e.picker?.searching != true {
            Log.write("search: list ended elsewhere (\(e.picker == nil ? "closed" : "replaced")) — closing the box. \(e.lastEvent)")
            e.lastEvent = ""
            searchOpen = false; dictation.stop(); legend.endSearch()
        }
        let m = legend.model
        m.layout = cfg.device.layout
        m.buttonLabels = cfg.device.layout.labels
        var controls: [String: Appearance] = [:]
        for c in cfg.device.allControlNames { controls[c] = e.appearance(c, ctx: context, snap: snap) }
        if controls != m.controls { m.controls = controls }
        // colour key: the statuses on window pads now, in a fixed order — from both pad banks, so the legend keeps
        // its height when PAD BANK flips the faces to bank B
        let notes = cfg.device.allControlNames.filter { $0.hasPrefix("pad") }
            .flatMap { n in [false, true].map { e.appearance(n, ctx: context, snap: snap, shift: $0) } }
            .filter { $0.windowSlot && !$0.note.isEmpty }.map(\.note)
        let key = Looks.statusWords.filter { w in notes.contains { $0 == w.1 || $0.contains(" \(w.1)") } }
            .map { StatusKeyItem(label: $0.1, hex: cfg.settings.ledColors[$0.0] ?? "#888888") }
        if key != m.statusKey { m.statusKey = key }
        var lights: [String: LegendLight] = [:]
        for (name, a) in controls { if let l = Self.light(a, cfg.settings) { lights[name] = LegendLight(hex: l.hex, level: l.level) } }
        if lights != m.lights { m.lights = lights }
        let path = e.layerPath(context, now: now, snap: snap)
        if m.path != path { m.path = path }
        let stack = e.effectiveStack(context, snap)
        m.layerColor = stack.last?.color ?? "#888888"
        let modal = stack.last?.kind == .modal
        let bankB = e.padBankLive && e.shiftActive && !e.shiftHeld        // pad bank B = the shift layer, shown as such
        m.frameStyle = modal ? .modal : (e.shiftHeld || bankB ? .held : (stack.count > 1 ? .temporary : .base))
        legend.showPicker(e.picker)
        // menus, questions and confirmations don't pop the legend up: the pads light and label themselves
        // (hold ▶ to see it). Status displays do (legend = true, e.g. the Agents overview): up while they're on.
        let statusDisplay = stack.contains { $0.showsLegend }
        if legend.forced != statusDisplay { legend.forced = statusDisplay; legend.update() }
        let connected = padSourcePresent
        m.connected = connected
        var conn = connected ? cfg.device.name : (ble?.status ?? "not connected")
        if let u5 = snap["usage.5h"].number { conn += " · 5h \(Int(u5))%" }
        if let u7 = snap["usage.7d"].number { conn += " · 7d \(Int(u7))%" }
        m.connection = conn
        var footer: [String] = []
        if let err = lastError { footer.append("⚠︎ \(err)") }
        if cfg.device.provisional { footer.append("Device profile is a guess — run `paddington learn` with the pad connected.") }
        if let r = snap["agents.oldest_waiting.reason"].string, let w = snap["agents.oldest_waiting.window"].int {
            footer.append("Waiting: window \(w) (\(r))")
        }
        let f = footer.joined(separator: "  ·  ")
        if m.footer != f { m.footer = f }
        if legend.visible { legend.update() }
        // [sleep] wake_for_agents: an agent that starts waiting for you lights the pad again
        let wanting = Set(agents.agents.values.filter { $0.status.wantsYou }.map(\.sessionId))
        if padSleep.asleep, cfg.settings.sleepWakeForAgents, !wanting.subtracting(wantedYou).isEmpty {
            padSleep.wake(now: now)
            Log.write("pad awake (an agent waits for you)")
        }
        wantedYou = wanting
        paintLEDs(cfg, e, snap)
        updateDrums(cfg, e, snap)

        let waiting = snap["agents.waiting"].int ?? 0
        let text = [waiting > 0 ? "\(waiting)" : "", lastError != nil ? "!" : ""].filter { !$0.isEmpty }.joined(separator: " ")
        setStatusIcon(connected: connected, text: text)
        rebuildMenu()
    }

    var statusIconSignature = ""
    /// Menu-bar icon: the pad's 4×4 grid, solid when the pad is connected, faint when not; text = waiting agents, "!" = error.
    func setStatusIcon(connected: Bool, text: String) {
        let sig = "\(connected)|\(text)"
        guard sig != statusIconSignature, let button = statusItem.button else { return }
        statusIconSignature = sig
        button.image = Self.padIcon(connected: connected)
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        button.title = text.isEmpty ? "" : " \(text)"
        button.toolTip = connected ? "Paddington — pad connected" : "Paddington — pad not connected"
    }

    static func padIcon(connected: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let gap: CGFloat = 1.4, side = (15 - 3 * gap) / 4
            for row in 0..<4 {
                for col in 0..<4 {
                    let r = NSRect(x: 0.5 + CGFloat(col) * (side + gap), y: 0.5 + CGFloat(row) * (side + gap), width: side, height: side)
                    let path = NSBezierPath(roundedRect: r, xRadius: 0.9, yRadius: 0.9)
                    if connected {
                        NSColor.black.setFill(); path.fill()
                    } else {
                        NSColor.black.withAlphaComponent(0.25).setFill(); path.fill()
                        NSColor.black.setStroke(); path.lineWidth = 0.8
                        NSBezierPath(roundedRect: r.insetBy(dx: 0.4, dy: 0.4), xRadius: 0.7, yRadius: 0.7).stroke()
                    }
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Pad lights: bank A notes show the normal layer, bank B notes the shift layer. Only changes are written.
    func paintLEDs(_ cfg: Config, _ e: Engine, _ snap: Snapshot) {
        let s = cfg.settings
        guard s.ledMode != "off", leds.ready else { return }
        for c in cfg.device.controls where c.kind == .pad {
            guard let note = c.note else { continue }
            let a = e.appearance(c.name, ctx: context, snap: snap, shift: c.bank == "B")
            let (hex, base) = Self.light(a, s) ?? ("#000000", 0)
            guard let v = UInt32(hex.dropFirst(), radix: 16), hex.hasPrefix("#") else { continue }
            var level = base * (ledNight ? s.ledNightScale : 1) * (padSleep.asleep ? s.sleepLevel : 1)
            if a.blink, s.ledMode == "live", Int(now * 2) % 2 == 1 { level *= 0.12 }   // blink at ~1 Hz
            func ch(_ x: UInt32) -> UInt8 { UInt8(min(255, Double(x & 0xFF) * level)) }
            leds.set(note: note, r: ch(v >> 16), g: ch(v >> 8), b: ch(v))
        }
    }

    /// padbeat's note map: every pad note (bank A and B) whose binding only plays a sample file.
    func updateDrums(_ cfg: Config, _ e: Engine, _ snap: Snapshot) {
        guard !testMode else { return }     // the map file is shared: a test copy must never touch it
        guard cfg.settings.soundsEnabled, !paused, !padSleep.asleep else { drums.update(source: cfg.device.match, entries: [:]); return }
        var entries: [Int: (String, Double)] = [:]
        for c in cfg.device.controls where c.kind == .pad {
            guard let note = c.note, let (b, _) = e.resolve(c.name, context, snap, shift: c.bank == "B"),
                  b.action == nil, let key = b.sound, let (path, gain) = SoundPlayer.file(key, settings: cfg.settings) else { continue }
            entries[note] = (path, min(1, cfg.settings.soundVolume * gain))
        }
        drums.update(source: cfg.device.match, entries: entries, curve: cfg.settings.drumCurve, floor: cfg.settings.drumFloor, full: cfg.settings.drumFull)
    }

    /// The colour and level a control's light shows; the legend draws the same thing. nil = dark.
    static func light(_ a: Appearance, _ s: Settings) -> (hex: String, level: Double)? {
        guard a.bound else { return nil }
        var key = a.key ?? "act"
        if s.ledMode == "groups", AgentStatus(rawValue: key) != nil { key = "nav" }
        guard let hex = s.ledColors[key] ?? a.color, hex != "#000000" else { return nil }
        return (hex, a.selected ? 1.0 : (a.windowSlot ? s.ledWindowBrightness : s.ledBrightness))
    }

    var menuSignature = ""
    func rebuildMenu() {
        let path = engine?.layerPath(context, now: now) ?? "-"
        let sig = "\(path)|\(lastError ?? "")|\(paused)|\(padSourcePresent)|\(ble?.status ?? "")|\(AXIsProcessTrusted())|\(Self.loginAgent.status.rawValue)|\(leds.status)|\(ledNight)|\(agentSounds)|\(padSleep.asleep)"
        guard sig != menuSignature else { return }
        menuSignature = sig
        let menu = NSMenu()
        func info(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func item(_ s: String, _ sel: Selector, _ key: String = "") { let i = NSMenuItem(title: s, action: sel, keyEquivalent: key); i.target = self; menu.addItem(i) }
        info("Paddington \(Paddington.version)")
        info(padSourcePresent ? "Pad: connected (\(config?.device.name ?? ""))" : "Pad: \(ble?.status ?? "not connected")")
        info("Layer: \(path)")
        if let e = lastError { info("⚠︎ \(e.prefix(120))") }
        if !AXIsProcessTrusted() { item("Grant Accessibility permission…", #selector(openAccessibility)) }
        menu.addItem(.separator())
        item("Show legend", #selector(showLegend), "l")
        item("Connect pad (Bluetooth)", #selector(connectBT))
        item("Bluetooth MIDI window…", #selector(pairingWindow))
        item("Open Audio MIDI Setup", #selector(audioMIDISetup))
        menu.addItem(.separator())
        item("Reload config", #selector(reloadMenu), "r")
        item("Open config folder", #selector(openConfig))
        item(paused ? "Resume" : "Pause", #selector(togglePause), "p")
        let login = NSMenuItem(title: "Start at login · restart after a crash", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = Self.loginAgent.status == .enabled ? .on : .off
        menu.addItem(login)
        info("Pad lights: \(leds.status)\(padSleep.asleep ? " · asleep — any press wakes them" : "")")
        if !padSleep.asleep { item("Sleep pad lights now", #selector(sleepNow)) }
        let night = NSMenuItem(title: "Dim pad lights (night)", action: #selector(toggleNight), keyEquivalent: "")
        night.target = self
        night.state = ledNight ? .on : .off
        menu.addItem(night)
        let sounds = NSMenuItem(title: "Agent sounds (asks · approve? · done · error)", action: #selector(toggleAgentSounds), keyEquivalent: "")
        sounds.target = self
        sounds.state = agentSounds ? .on : .off
        menu.addItem(sounds)
        menu.addItem(.separator())
        item("Quit Paddington", #selector(quit), "q")
        statusItem.menu = menu
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func showLegend() { legend.apply(.togglePin) }
    @objc func connectBT() { ble?.connect() }
    @objc func pairingWindow() { ble?.showPairingWindow() }
    @objc func audioMIDISetup() { BLEMIDIConnector.openAudioMIDISetup() }
    @objc func reloadMenu() { reloadConfig(initial: false) }
    @objc func openConfig() { NSWorkspace.shared.open(Config.defaultRoot) }
    @objc func togglePause() {
        paused.toggle()
        if paused, let e = engine { process(e.releaseAll()) }
        legend.toast(paused ? "Paddington paused" : "Paddington resumed")
        render()
    }
    @objc func quit() { drums.stop(); NSApp.terminate(nil) }
    /// Day/night pad lights: night scales every level by [led] night (default 0.3). Remembered across restarts.
    var ledNight: Bool {
        get { UserDefaults.standard.bool(forKey: "ledNight") }
        set { UserDefaults.standard.set(newValue, forKey: "ledNight") }
    }
    /// Agent sounds: a short cue when an agent starts waiting for you or errors. On unless muted; remembered.
    var agentSounds: Bool {
        get { UserDefaults.standard.object(forKey: "agentSounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "agentSounds") }
    }
    @objc func toggleAgentSounds() {
        agentSounds.toggle()
        legend.toast(agentSounds ? "Agent sounds on" : "Agent sounds muted")
        menuSignature = ""
        render()
    }

    /// Each agent's last status, so a change into asks / approve? / done / error plays its sound once.
    var lastAgentStatus: [String: AgentStatus] = [:]
    func playAgentSounds(_ settings: Settings) {
        let current = agents.agents.mapValues(\.status)
        defer { lastAgentStatus = current }
        guard agentSounds, !paused, !testMode else { return }
        let keys: [AgentStatus: String] = [.needs_input: "agent_asks", .needs_approval: "agent_approve",
                                           .done_unread: "agent_done", .error: "agent_error"]
        // the pane you're looking at needs no sound; the most urgent change wins when several happen at once
        let changed = agents.agents.values.filter { a in
            a.status != lastAgentStatus[a.sessionId] && keys[a.status] != nil
                && !(context.app == ITerm.bundleId && a.pane == context.focusedPane?.paneId)
        }
        guard let top = changed.max(by: { $0.status.urgency < $1.status.urgency }), let key = keys[top.status] else { return }
        Log.write("agent sound: \(key) (\(top.pane))")
        sounds.play(key, settings: settings)
    }

    @objc func toggleNight() {
        ledNight.toggle()
        legend.toast(ledNight ? "Pad lights dimmed (night)" : "Pad lights bright (day)")
        menuSignature = ""
        render()
    }
    /// A launchd agent inside the bundle (Contents/Library/LaunchAgents): starts paddington at login and, unlike a
    /// plain login item, starts it again if it crashes (KeepAlive on a failed exit). Quit from the menu stays quit.
    static let agentLabel = "com.pkronstrom.padctl.agent"
    static let loginAgent = SMAppService.agent(plistName: "\(agentLabel).plist")

    @objc func toggleLogin() {
        do {
            if Self.loginAgent.status == .enabled { try Self.loginAgent.unregister(); legend.toast("Paddington won't start at login") }
            else { try Self.loginAgent.register(); legend.toast("Paddington starts at login and restarts after a crash") }
        } catch { legend.toast("Login item: \(error.localizedDescription)") }
        menuSignature = ""
        rebuildMenu()
    }

    /// The old plain login item becomes the agent (same choice, plus crash restart).
    func migrateLoginItem() {
        guard !testMode, SMAppService.mainApp.status == .enabled else { return }
        try? SMAppService.mainApp.unregister()
        do { try Self.loginAgent.register(); Log.write("login item → launchd agent") } catch { Log.write("agent register: \(error)") }
    }

    // MARK: socket commands

    func handle(_ req: [String: Any]) -> [String: Any] {
        let cmd = req["cmd"] as? String ?? ""
        switch cmd {
        case "hook":
            let event = req["event"] as? String ?? ""
            let payload = (Value(any: req["payload"]).table) ?? [:]
            let pane = req["pane"] as? String
            if agents.handle(event: event, payload: payload, pane: pane, now: now) { render() }
            return ["ok": true]
        case "statusline":
            let payload = Value(any: req["payload"]).table ?? [:]
            if agents.statusline(payload: payload, pane: req["pane"] as? String, now: now) { render() }
            return ["ok": true]
        case "state_set":
            guard let k = req["key"] as? String else { return ["ok": false, "error": "missing key"] }
            setState(k, Value(any: req["value"]))
            return ["ok": true]
        case "state_get":
            let snap = snapshot()
            var out: [String: Any] = [:]
            for (k, v) in snap.values { out[k] = v.jsonObject }
            out["agents"] = agents.agents.values.map { ["session": $0.sessionId, "pane": $0.pane, "status": $0.status.rawValue,
                                                        "reason": $0.reason, "mode": $0.mode] }
            return ["ok": true, "state": out]
        case "simulate":
            guard let c = req["control"] as? String else { return ["ok": false, "error": "missing control"] }
            let kind = req["event"] as? String ?? "tap"
            switch kind {
            case "down": input(.down(c))
            case "up": input(.up(c))
            case "turn": input(.turn(c, req["delta"] as? Int ?? 1))
            case "hold":
                input(.down(c))
                let secs = (req["seconds"] as? Double) ?? 1.2
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in self?.input(.up(c)) }
            default: input(.down(c)); DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.input(.up(c)) }
            }
            return ["ok": true, "layer": engine?.layerPath(context, now: now) ?? ""]
        case "status":
            return ["ok": true, "version": Paddington.version, "connected": padSourcePresent, "bluetooth": ble?.status ?? "",
                    "layer": engine?.layerPath(context, now: now, snap: snapshot()) ?? "", "error": lastError ?? NSNull(),
                    "warnings": config?.warnings ?? [], "app": context.app, "pane": context.focusedPane?.paneId ?? NSNull(),
                    "tty": clientTTY ?? NSNull(), "tmux_panes": context.panes.count,
                    "tmux_probe": { () -> String in
                        do { return "which=\(Shell.which("tmux") ?? "none") panes=\(try Tmux.panesOrError().count) clients=\(Tmux.clients().count)" }
                        catch { return "which=\(Shell.which("tmux") ?? "none") error: \(error)" }
                    }(), "sandboxed": Self.sandboxed,
                    "pad_bank": engine?.padBank ?? "?", "knob_bank": engine?.knobBank ?? "?",
                    "drums": ["padbeat": drums.running, "notes": drums.notes.sorted()] as [String: Any],
                    "tmux_clients": Tmux.clients().map { "\($0.tty) \($0.session)" },
                    "accessibility": AXIsProcessTrusted(), "paused": paused, "asleep": padSleep.asleep,
                    "sources": MIDIService.sources().map { "\($0.name)\($0.online ? "" : " (offline)")" }]
        case "reload":
            if let err = reloadConfig(initial: false) { return ["ok": false, "error": err] }
            return ["ok": true, "warnings": config?.warnings ?? []]
        case "legend":
            switch req["action"] as? String ?? "pin" {
            case "show": legend.apply(.showHeld)
            case "hide": legend.apply(.hideHeld)
            default: legend.apply(.togglePin)
            }
            return ["ok": true]
        case "bt_connect": ble?.connect(); return ["ok": true, "status": ble?.status ?? ""]
        case "drums":
            drums.report()
            return ["ok": true, "padbeat": drums.running, "notes": drums.notes.sorted(), "pad_bank": engine?.padBank ?? "?"]
        case "render_legend":
            guard let path = req["path"] as? String else { return ["ok": false, "error": "missing path"] }
            render()
            let ok = MainActor.assumeIsolated { legend.renderPNG(to: path) }
            return ok ? ["ok": true] : ["ok": false, "error": "render failed"]
        case "bt_window": ble?.showPairingWindow(); return ["ok": true]
        case "pad":
            switch req["action"] as? String ?? "global" {
            case "dump":
                guard leds.ready else { return ["ok": false, "error": "the pad's light session isn't up (\(leds.status))"] }
                leds.dumpConfig()
                return ["ok": true, "file": "~/Library/Application Support/paddington/pad-config.bin (in ~5 s)"]
            case "probe":
                if let b = req["bytes"] as? [Int], !b.isEmpty { return probeSideLights(bytes: b, hold: 6) }
                return probeSideLights()
            case "set":
                guard let i = req["index"] as? Int, let v = req["value"] as? Int, (0...255).contains(v), leds.ready else {
                    return ["ok": false, "error": "need index 0–11, value 0–255 and the pad's light session"]
                }
                leds.writeGlobal(index: i, value: UInt8(v))
                return ["ok": true]
            default:
                let w = leds.written
                return ["ok": true, "global": PadLEDs.hex(leds.global), "lights": leds.status, "pad_bank": engine?.padBank ?? "?",
                        "bank_a": (36...51).map { w[$0] ?? "-" }.joined(separator: " "),
                        "bank_b": (52...67).map { w[$0] ?? "-" }.joined(separator: " ")]
            }
        case "leds":
            switch req["action"] as? String ?? "status" {
            case "start": leds.start()
            case "stop": leds.stop()
            case "set":
                guard let n = req["note"] as? Int, let hex = req["color"] as? String, let v = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) else {
                    return ["ok": false, "error": "need note and color"]
                }
                leds.set(note: n, r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
            case "test":
                let colours: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (255, 120, 0), (255, 220, 0), (0, 200, 60), (0, 160, 255), (60, 60, 255), (170, 0, 255), (255, 0, 160)]
                for i in 0..<16 { let c = colours[i % 8]; leds.set(note: 36 + i, r: c.0, g: c.1, b: c.2) }
            default: break
            }
            return ["ok": true, "status": leds.status, "ready": leds.ready]
        default: return ["ok": false, "error": "unknown command '\(cmd)'"]
        }
    }
}
