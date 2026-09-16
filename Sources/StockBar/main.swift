import AppKit
import SwiftUI
import StockBarCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var item: NSStatusItem!
    private let panel = QuotePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let menuIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: "StockBar")
        image?.isTemplate = true; image?.size = NSSize(width: 17, height: 17)
        return image
    }()
    private var store: AppStore!
    private var previewWindow: NSWindow?
    private var appliedPanelSize = CGSize.zero
    private var observers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store = AppStore()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button { button.target = self; button.action = #selector(togglePanel); button.sendAction(on: [.leftMouseUp, .rightMouseUp]) }
        panel.delegate = self; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.level = .popUpMenu; panel.hasShadow = true; panel.isReleasedWhenClosed = false
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.type == .keyDown && event.keyCode == 53 {
                if self.store.supportVisible { self.store.supportVisible = false } else { self.closePanel() }
                return nil
            }
            if event.type != .keyDown, let window = event.window, window === self.previewWindow { self.closePanel() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.closePanel() }
        panel.contentViewController = NSHostingController(rootView: PanelView(store: store))
        store.changed = { [weak self] in self?.updateTitle(); self?.updateLayout() }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.store.setSleeping(true) } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.store.setSleeping(false) } })
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.closePanel() } }
        updateLayout(); updateTitle(); store.start()
        if ProcessInfo.processInfo.arguments.contains("--qa-window") {
            NSApp.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: appliedPanelSize.width, height: appliedPanelSize.height), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "StockBar · 界面验证"
            window.isOpaque = false; window.backgroundColor = .clear
            window.contentViewController = NSHostingController(rootView: PanelView(store: store, panelSize: appliedPanelSize))
            window.center(); window.makeKeyAndOrderFront(nil); previewWindow = window
            store.setPanelVisible(true); NSApp.activate(ignoringOtherApps: true)
        } else if ProcessInfo.processInfo.arguments.contains("--show-panel") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showPanel() } }
    }
    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let open = NSMenuItem(title: "打开 StockBar", action: #selector(openPanel), keyEquivalent: ""); open.target = self; menu.addItem(open)
            let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
            menu.addItem(.separator()); menu.addItem(withTitle: "退出 StockBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu; item.button?.performClick(nil); item.menu = nil
        } else if panel.isVisible { closePanel() } else { showPanel() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
    @objc private func openPanel() { showPanel() }
    @objc private func openSettings() { store.selectedPage = 1; showPanel() }
    private func showPanel() {
        guard let button = item.button, let window = button.window, let screen = window.screen else { return }
        showPanel(anchor: window.convertToScreen(button.convert(button.bounds, to: nil)), screen: screen)
    }
    private func showPanel(anchor: NSRect, screen: NSScreen) {
        updateLayout()
        let frame = PanelPlacement.frame(anchor: anchor, size: appliedPanelSize, visible: screen.visibleFrame)
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        store.setPanelVisible(true)
    }
    private func closePanel() { store.supportVisible = false; panel.orderOut(nil); store.setPanelVisible(previewWindow?.isVisible == true) }
    func windowDidResignKey(_ notification: Notification) {
        // Native menus temporarily take key status; outside-click monitoring handles dismissal.
    }
    private func updateLayout() {
        let visible = (item.button?.window?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let compactTest = ProcessInfo.processInfo.arguments.contains("--qa-small")
        let size = CGSize(width: min(compactTest ? 420 : 480, max(340, visible.width - 32)), height: min(compactTest ? 440 : store.preferences.compact ? 500 : 600, max(320, visible.height - 48)))
        guard size != appliedPanelSize else { return }
        appliedPanelSize = size
        if let host = panel.contentViewController as? NSHostingController<PanelView> { host.rootView = PanelView(store: store, panelSize: size) }
        let top = panel.frame.maxY
        panel.setContentSize(size)
        if panel.isVisible { panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - size.height)) }
        if let window = previewWindow, let host = window.contentViewController as? NSHostingController<PanelView> {
            host.rootView = PanelView(store: store, panelSize: size); window.setContentSize(size)
        }
    }
    private func updateTitle() {
        guard let button = item.button else { return }
        if store.preferences.menuStyle == .icon {
            if button.image !== menuIcon {
                item.length = NSStatusItem.squareLength
                button.attributedTitle = NSAttributedString(string: "")
                button.image = menuIcon; button.imagePosition = .imageOnly
            }
            button.toolTip = "StockBar · 点击查看 \(store.preferences.instruments.count) 个自选"
            button.setAccessibilityLabel("StockBar，点击打开自选行情")
            return
        }
        button.image = nil; button.imagePosition = .noImage
        let title = store.menuTitle
        var color = NSColor.labelColor
        if let instrument = store.displayedInstrument, let quote = store.quotes[instrument.id] {
            color = store.preferences.monochrome ? .labelColor : NSColor(store.color(quote))
            button.toolTip = "\(quote.name) \(store.price(quote, instrument: instrument))\n\(store.sourceName(quote.sourceID)) · 行情时间 \(store.time(quote.quoteTime))\(store.isOld(quote) ? "\n旧值 / 待更新" : "")"
        } else { button.toolTip = "点击管理自选行情" }
        var fontSize = CGFloat(store.preferences.menuFontSize)
        var attributed = NSAttributedString(string: title, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium), .foregroundColor: color])
        while attributed.size().width > CGFloat(store.preferences.menuWidth - 16) && fontSize > 9 {
            fontSize -= 0.5
            attributed = NSAttributedString(string: title, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium), .foregroundColor: color])
        }
        item.length = min(CGFloat(store.preferences.menuWidth), max(48, attributed.size().width + 16))
        button.cell?.lineBreakMode = .byTruncatingTail
        if !button.attributedTitle.isEqual(to: attributed) { button.attributedTitle = attributed }
        button.setAccessibilityLabel("StockBar，\(title)")
    }
    func applicationWillTerminate(_ notification: Notification) {
        store?.shutdown()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

// The same binary supports a read-only native networking check, without launching UI.
if CommandLine.arguments.contains("--smoke-test") {
    Task {
        var failed = false
        for provider in ProviderRegistry.standard().providers {
            do {
                let result = try await provider.fetch(Instrument.defaults)
                let valid = result.count == Instrument.defaults.count
                print("\(provider.descriptor.name): \(valid ? "PASS" : "FAIL") \(result.count)/\(Instrument.defaults.count) quotes")
                for key in result.keys.sorted() { let q = result[key]!; print("  \(key) \(q.name) \(q.price) \(q.changePercent)% \(q.quoteTime)") }
                if !valid { failed = true }
            } catch { print("\(provider.descriptor.name): FAIL \(error.localizedDescription)"); failed = true }
        }
        exit(failed ? 1 : 0)
    }
    dispatchMain()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
