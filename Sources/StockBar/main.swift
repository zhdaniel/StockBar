import AppKit
import QuartzCore
import SwiftUI
import StockBarCore

private final class StatusTickerView: NSView {
    private let horizontalPadding: CGFloat = 8
    private var trackLayer = CALayer()
    private var displayedValue: NSAttributedString?
    private var scrolling = false
    private var speed: CGFloat = 30
    private var cycleWidth: CGFloat = 0
    private var lastSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(trackLayer)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setContent(_ value: NSAttributedString, scrolling: Bool, speed: CGFloat) {
        guard displayedValue?.isEqual(to: value) != true || self.scrolling != scrolling || self.speed != speed else { return }
        let phase = currentPhase
        displayedValue = value
        self.scrolling = scrolling
        self.speed = speed
        cycleWidth = max(1, ceil(value.size().width))
        rebuildLayers(from: phase)
    }

    func stop() { trackLayer.removeAnimation(forKey: "stockbarMarquee") }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize, displayedValue != nil else { return }
        rebuildLayers(from: currentPhase)
    }

    private var currentPhase: CGFloat {
        guard cycleWidth > 0,
              let number = trackLayer.presentation()?.value(forKeyPath: "transform.translation.x") as? NSNumber else { return 0 }
        return ((-CGFloat(truncating: number) / cycleWidth).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
    }

    private func rebuildLayers(from phase: CGFloat) {
        guard let displayedValue else { return }
        lastSize = bounds.size

        let copies = scrolling ? max(2, Int(ceil(bounds.width / cycleWidth)) + 2) : 1
        let originX = scrolling ? 0 : horizontalPadding
        let nextTrack = CALayer()
        nextTrack.frame = NSRect(x: originX, y: 0, width: cycleWidth * CGFloat(copies), height: bounds.height)
        nextTrack.setAffineTransform(CGAffineTransform(translationX: scrolling ? -phase * cycleWidth : 0, y: 0))
        let textHeight = ceil(displayedValue.size().height) + 2
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for index in 0..<copies {
            let textLayer = CATextLayer()
            textLayer.string = displayedValue
            textLayer.contentsScale = scale
            textLayer.isWrapped = false
            textLayer.truncationMode = .none
            textLayer.alignmentMode = .left
            textLayer.frame = NSRect(
                x: CGFloat(index) * cycleWidth,
                y: floor((bounds.height - textHeight) / 2),
                width: cycleWidth,
                height: textHeight
            )
            nextTrack.addSublayer(textLayer)
        }
        if scrolling, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { startScrolling(nextTrack, from: phase) }

        let previousTrack = trackLayer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.addSublayer(nextTrack)
        trackLayer = nextTrack
        CATransaction.setCompletionBlock { previousTrack.removeFromSuperlayer() }
        CATransaction.commit()
    }

    private func startScrolling(_ layer: CALayer, from phase: CGFloat) {
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -phase * cycleWidth
        animation.toValue = -(phase + 1) * cycleWidth
        animation.duration = CFTimeInterval(cycleWidth / max(1, speed))
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "stockbarMarquee")
    }
}

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
    private var tickerView: StatusTickerView?
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
            tickerView?.stop()
            tickerView?.isHidden = true
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
        if let instrument = store.displayedInstrument, let quote = store.quotes[instrument.id] {
            button.toolTip = "\(quote.name) \(store.price(quote, instrument: instrument))\n\(store.sourceName(quote.sourceID)) · 行情时间 \(store.time(quote.quoteTime))\(store.isOld(quote) ? "\n旧值 / 待更新" : "")"
        } else { button.toolTip = "点击管理自选行情" }

        let shouldScroll = store.rotatesMenuQuotes && store.preferences.instruments.count > 1
        let attributed: NSAttributedString
        if shouldScroll {
            let sequence = NSMutableAttributedString()
            let separator = NSAttributedString(
                string: "\u{00A0}\u{00A0}\u{00A0}",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: CGFloat(store.preferences.menuFontSize), weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            sequence.append(separator)
            for (index, instrument) in store.preferences.instruments.enumerated() {
                sequence.append(attributedTitle(for: instrument))
                if index < store.preferences.instruments.count - 1 { sequence.append(separator) }
            }
            attributed = sequence
            item.length = CGFloat(store.preferences.menuWidth)
        } else {
            attributed = store.displayedInstrument.map(attributedTitle(for:)) ?? attributedTitle(text: title, color: .labelColor)
            item.length = min(CGFloat(store.preferences.menuWidth), max(48, attributed.size().width + 16))
        }
        button.attributedTitle = NSAttributedString(string: "")
        let ticker: StatusTickerView
        if let tickerView {
            ticker = tickerView
        } else {
            ticker = StatusTickerView(frame: button.bounds)
            ticker.autoresizingMask = [.width, .height]
            button.addSubview(ticker)
            tickerView = ticker
        }
        ticker.isHidden = false
        ticker.frame = button.bounds
        ticker.setContent(attributed, scrolling: shouldScroll, speed: marqueeSpeed)
        button.setAccessibilityLabel(shouldScroll ? "StockBar，连续滚动显示 \(store.preferences.instruments.count) 个自选" : "StockBar，\(title)")
    }

    private var marqueeSpeed: CGFloat {
        switch store.preferences.rotationSeconds {
        case 5: return 36
        case 8: return 28
        case 15: return 20
        default: return 14
        }
    }

    private func attributedTitle(for instrument: Instrument) -> NSAttributedString {
        let quote = store.quotes[instrument.id]
        let color = quote.map { store.preferences.monochrome ? NSColor.labelColor : NSColor(store.color($0)) } ?? .labelColor
        return attributedTitle(text: store.menuTitle(for: instrument), color: color)
    }

    private func attributedTitle(text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: CGFloat(store.preferences.menuFontSize), weight: .medium),
                .foregroundColor: color
            ]
        )
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
