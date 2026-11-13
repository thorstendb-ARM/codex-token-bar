import AppKit

/// A hover must start over the button; refreshes and late tracking events cannot arm it.
struct TooltipHoverSession {
    private(set) var startedAt: TimeInterval?
    private var dismissed = false
    var isTracking: Bool { startedAt != nil }

    mutating func enter(at time: TimeInterval, isInside: Bool) {
        guard isInside, !isTracking else { return }
        startedAt = time
        dismissed = false
    }

    mutating func update(at time: TimeInterval, isInside: Bool) -> Bool {
        guard isInside else {
            self = Self()
            return false
        }
        guard let startedAt, !dismissed else { return false }
        return time - startedAt >= 0.7
    }

    mutating func dismiss() {
        dismissed = true
    }
}

enum TooltipPlacement {
    static func frame(size: NSSize, anchor: NSRect, visibleFrame: NSRect) -> NSRect {
        let available = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(size.width, available.width)
        let height = min(size.height, available.height)
        let x = min(max(anchor.midX - width / 2, available.minX), available.maxX - width)
        let below = anchor.minY - height - 8
        let y = min(max(below, available.minY), available.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

/// Own the tooltip's lifetime instead of relying on NSStatusBarButton.toolTip.
/// Poll only during a hover, so a missed mouseExited cannot strand the window.
final class StatusItemTooltip: NSResponder {
    private weak var button: NSStatusBarButton?
    private var trackingArea: NSTrackingArea?
    private var session = TooltipHoverSession()
    private var timer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var text = ""
    private var shownAnchor: NSRect?
    private var menuIsOpen = false
    private let panel = TooltipPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: true)
    private let label = NSTextField(wrappingLabelWithString: "")

    init(button: NSStatusBarButton) {
        self.button = button
        super.init()
        button.toolTip = nil
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        button.addTrackingArea(area)
        trackingArea = area

        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        panel.contentView = background
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        background.addSubview(label)

        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            center.addObserver(self, selector: #selector(contextDidChange(_:)), name: name, object: nil)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(contextDidChange(_:)), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        invalidate()
    }

    func invalidate() {
        stopMonitoring()
        panel.orderOut(nil)
        if let trackingArea { button?.removeTrackingArea(trackingArea) }
        trackingArea = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func update(text: String) {
        self.text = text
        button?.setAccessibilityHelp(text)
        // A periodic data refresh must never create a new hover session.
        if panel.isVisible { dismiss() }
    }

    func setMenuOpen(_ isOpen: Bool) {
        menuIsOpen = isOpen
        dismiss()
    }

    override func mouseEntered(with event: NSEvent) {
        guard !menuIsOpen, NSEvent.pressedMouseButtons == 0 else { return }
        let isInside = anchor().map { $0.rect.contains(NSEvent.mouseLocation) } ?? false
        session.enter(at: ProcessInfo.processInfo.systemUptime, isInside: isInside)
        guard session.isTracking, timer == nil else { return }

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkHover() }
        timer.tolerance = 0.02
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in self?.dismiss() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            self?.dismiss()
            return event
        }
    }

    override func mouseExited(with event: NSEvent) {
        // AppKit can deliver enter/exit messages out of order. Check the real pointer.
        checkHover()
    }

    @objc private func contextDidChange(_ notification: Notification) {
        dismiss()
    }

    private func dismiss() {
        session.dismiss()
        panel.orderOut(nil)
        shownAnchor = nil
        // Keep checking until the pointer leaves; clicks must not immediately reopen it.
    }

    private func checkHover() {
        let anchor = anchor()
        let isInside = anchor.map { $0.rect.contains(NSEvent.mouseLocation) } ?? false
        let shouldShow = session.update(at: ProcessInfo.processInfo.systemUptime, isInside: isInside)
        guard session.isTracking else {
            dismiss()
            stopMonitoring()
            return
        }
        if menuIsOpen || NSEvent.pressedMouseButtons != 0 || (shownAnchor != nil && shownAnchor != anchor?.rect) {
            dismiss()
            return
        }
        guard shouldShow, !panel.isVisible, !text.isEmpty, let anchor else { return }
        label.stringValue = text
        let width = min(440, anchor.screen.visibleFrame.width - 40)
        let textSize = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        let frame = TooltipPlacement.frame(size: NSSize(width: width + 20, height: ceil(textSize.height) + 16),
                                           anchor: anchor.rect, visibleFrame: anchor.screen.visibleFrame)
        label.frame = NSRect(x: 10, y: 8, width: frame.width - 20, height: frame.height - 16)
        panel.setFrame(frame, display: false)
        shownAnchor = anchor.rect
        panel.orderFrontRegardless()
    }

    private func anchor() -> (rect: NSRect, screen: NSScreen)? {
        guard let button, !button.isHiddenOrHasHiddenAncestor, !button.visibleRect.isEmpty,
              let window = button.window, window.isVisible, let screen = window.screen else { return nil }
        let rect = window.convertToScreen(button.convert(button.visibleRect, to: nil))
        guard !rect.isEmpty, screen.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) else { return nil }
        return (rect, screen)
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }
}

private final class TooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
