import AppKit
import TokenBarCore

final class StatusBarController: NSObject, NSApplicationDelegate {
    private let builder: ReportBuilder
    private let worker = DispatchQueue(label: "CodexTokenBar.usage-index", qos: .utility)
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var periodItems: [UsagePeriod: NSMenuItem] = [:]
    private let messageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "Aktualisieren", action: #selector(refresh), keyEquivalent: "r")
    private let resetCurrentItem = NSMenuItem(title: "Current zurücksetzen", action: #selector(resetCurrent), keyEquivalent: "")
    private let currentStartedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let tokensItem = NSMenuItem(title: "Tokens", action: #selector(toggleTokens), keyEquivalent: "")
    private let dollarsItem = NSMenuItem(title: "Dollar", action: #selector(toggleDollars), keyEquivalent: "")
    private var timer: Timer?
    private var report: UsageReport?
    private var errorMessage: String?
    private var isScanning = false
    private var scanProgress: IndexProgress?
    private var lastProgressUpdate = Date.distantPast
    private var settings = DisplaySettings()

    init(configuration: AppConfiguration) {
        builder = ReportBuilder(configuration: configuration)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.setAccessibilityLabel("Codex Token Usage")
        }

        menu.autoenablesItems = false
        for period in UsagePeriod.allCases {
            let item = NSMenuItem(title: "", action: #selector(selectPeriod(_:)), keyEquivalent: "")
            item.representedObject = period.rawValue
            item.target = self
            menu.addItem(item)
            periodItems[period] = item
        }
        menu.addItem(.separator())
        currentStartedItem.isEnabled = false
        menu.addItem(currentStartedItem)
        resetCurrentItem.target = self
        menu.addItem(resetCurrentItem)
        menu.addItem(.separator())
        tokensItem.target = self
        dollarsItem.target = self
        menu.addItem(tokensItem)
        menu.addItem(dollarsItem)
        menu.addItem(.separator())
        messageItem.isEnabled = false
        messageItem.isHidden = true
        menu.addItem(messageItem)
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quit = NSMenuItem(title: "Beenden", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu

        updateDisplay()
        refresh()
        let refreshTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer = refreshTimer
        RunLoop.main.add(refreshTimer, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    @objc private func selectPeriod(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let period = UsagePeriod(rawValue: rawValue) else { return }
        settings.select(period)
        updateDisplay()
    }

    @objc private func toggleTokens() {
        settings.toggleTokens()
        updateDisplay()
    }

    @objc private func toggleDollars() {
        settings.toggleDollars()
        updateDisplay()
    }

    @objc private func resetCurrent() {
        settings.resetCurrent()
        report?.resetCurrent(startedAt: settings.currentStartedAt)
        updateDisplay()
        refresh()
    }

    @objc private func refresh() {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = nil
        lastProgressUpdate = .distantPast
        let currentStartedAt = settings.currentStartedAt
        updateDisplay()

        worker.async { [weak self] in
            guard let self else { return }
            let result: Result<UsageReport, Error>
            do {
                let report = try self.builder.scan(currentStartedAt: currentStartedAt) { [weak self] progress in
                    DispatchQueue.main.async { self?.updateProgress(progress) }
                }
                result = .success(report)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isScanning = false
                self.scanProgress = nil
                let wasReset = currentStartedAt != self.settings.currentStartedAt
                switch result {
                case .success(var report):
                    if wasReset { report.resetCurrent(startedAt: self.settings.currentStartedAt) }
                    self.report = report
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
                self.updateDisplay()
                // A reset during scanning needs a fresh snapshot, even if that scan failed.
                if wasReset { self.refresh() }
            }
        }
    }

    private func updateProgress(_ progress: IndexProgress) {
        guard isScanning else { return }
        scanProgress = progress
        let now = Date()
        if now.timeIntervalSince(lastProgressUpdate) >= 0.2 || progress.completed == progress.total {
            lastProgressUpdate = now
            updateDisplay()
        }
    }

    private func updateDisplay() {
        let hasIndexWarnings = (report?.indexWarningCount ?? 0) > 0
        let currentStart = settings.currentStartedAt.formatted(date: .abbreviated, time: .standard)
        for period in UsagePeriod.allCases {
            let item = periodItems[period]
            item?.title = periodTitle(period, expanded: true)
            item?.state = period == settings.selectedPeriod ? .on : .off
            item?.toolTip = period == .current ? "\(period.title) · Seit: \(currentStart)" : period.title
        }

        var title = periodTitle(settings.selectedPeriod)
        if errorMessage != nil || hasIndexWarnings { title += " ⚠︎" }
        statusItem?.button?.title = title
        statusItem?.button?.toolTip = tooltip()
        refreshItem.isEnabled = !isScanning
        currentStartedItem.title = "Current seit: \(currentStart)"
        resetCurrentItem.toolTip = "Startet eine neue manuelle Messung bei null und zeigt Current in der Menüleiste."
        tokensItem.state = settings.showTokens ? .on : .off
        dollarsItem.state = settings.showDollars ? .on : .off
        tokensItem.isEnabled = settings.canToggleTokens
        dollarsItem.isEnabled = settings.canToggleDollars

        if let errorMessage {
            messageItem.title = "Fehler: \(singleLine(errorMessage))"
            messageItem.toolTip = errorMessage
            messageItem.isHidden = false
        } else if isScanning {
            if let progress = scanProgress, progress.total > 0 {
                messageItem.title = "Aktualisierung: \(progress.completed)/\(progress.total)"
            } else {
                messageItem.title = "Aktualisierung …"
            }
            messageItem.toolTip = nil
            messageItem.isHidden = false
        } else if let warnings = report?.warnings, !warnings.isEmpty {
            messageItem.title = "\(warnings.count) Hinweis\(warnings.count == 1 ? "" : "e") · Details im Tooltip"
            messageItem.toolTip = warnings.joined(separator: "\n")
            messageItem.isHidden = false
        } else {
            messageItem.isHidden = true
            messageItem.toolTip = nil
        }
    }

    private func periodTitle(_ period: UsagePeriod, expanded: Bool = false) -> String {
        if let values = report?.periods[period.rawValue] {
            return settings.title(for: period, totals: values, expanded: expanded)
        }
        return settings.placeholderTitle(for: period, hasError: errorMessage != nil, expanded: expanded)
    }

    private func tooltip() -> String {
        var lines = ["Codex Token Usage · \(settings.selectedPeriod.title)",
                     "Kosten: USD-Schätzung mit API-Standardpreisen; keine Abrechnung."]
        if settings.selectedPeriod == .current {
            lines.append("Messung seit: \(settings.currentStartedAt.formatted(date: .abbreviated, time: .standard))")
        }
        if let period = report?.periods[settings.selectedPeriod.rawValue] {
            lines.append("\(period.totalTokens) Tokens")
            if period.unpricedEvents > 0 {
                lines.append("+ ? = Preis unbekannt für \(period.unpricedEvents) Ereignisse / \(period.unpricedTokens) Tokens.")
            }
        }
        if let report {
            lines.append("Preisstand: \(report.pricingAsOf)")
            lines.append("Preisquelle: \(report.pricingSource)")
            lines.append("Stand: \(report.scannedAt.formatted(date: .abbreviated, time: .standard))")
            lines.append(contentsOf: report.warnings)
        }
        if let errorMessage {
            lines.append("Aktualisierung fehlgeschlagen: \(errorMessage)")
            if report != nil { lines.append("Angezeigt wird der letzte erfolgreiche Stand.") }
        }
        return lines.joined(separator: "\n")
    }

    private func singleLine(_ value: String) -> String {
        let line = value.components(separatedBy: .newlines).joined(separator: " ")
        return line.count > 95 ? String(line.prefix(92)) + "…" : line
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
