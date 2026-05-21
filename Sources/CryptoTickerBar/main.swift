import AppKit
import Foundation
import UserNotifications

enum TrackedAsset: String, CaseIterable, Codable, Hashable, Sendable {
    case btc = "BTCUSDT"
    case eth = "ETHUSDT"
    case bnb = "BNBUSDT"
    case sol = "SOLUSDT"

    var displayName: String {
        switch self {
        case .btc:
            return "BTC"
        case .eth:
            return "ETH"
        case .bnb:
            return "BNB"
        case .sol:
            return "SOL"
        }
    }
}

enum AlertDirection: String, Codable, CaseIterable {
    case belowOrEqual = "belowOrEqual"
    case aboveOrEqual = "aboveOrEqual"

    var displayName: String {
        switch self {
        case .belowOrEqual:
            return "<="
        case .aboveOrEqual:
            return ">="
        }
    }
}

struct PriceAlertRule: Codable {
    var asset: TrackedAsset
    var direction: AlertDirection
    var threshold: Double

    var key: String {
        "\(asset.rawValue)-\(direction.rawValue)-\(threshold)"
    }
}

struct TickerResponse: Decodable {
    let symbol: String
    let price: String
}

struct OKXTickerResponse: Decodable {
    let data: [OKXTicker]
}

struct OKXTicker: Decodable {
    let instId: String
    let last: String
}

struct MEXCTickerResponse: Decodable {
    let symbol: String
    let price: String
}

struct GateTickerResponse: Decodable {
    let currencyPair: String
    let last: String

    enum CodingKeys: String, CodingKey {
        case currencyPair = "currency_pair"
        case last
    }
}

struct PriceQuote {
    let price: Double
    let source: String
}

struct AssetFetchResult: Sendable {
    let rawAsset: String
    let price: Double?
    let source: String?
    let errorMessage: String?
}

enum ErrorDescription {
    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        if let urlError = error as? URLError {
            return urlError.localizedDescription
        }
        if let decodingError = error as? DecodingError {
            return "\(decodingError)"
        }
        return String(describing: error)
    }
}

enum AppLog {
    private static let url = URL(fileURLWithPath: "/private/tmp/CryptoTickerBar.log")
    private static let queue = DispatchQueue(label: "CryptoTickerBar.AppLog")

    static func write(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else {
                return
            }

            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }

            do {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                NSLog("CryptoTickerBar log write failed: \(error)")
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

struct AppSettings {
    var assets: [TrackedAsset]
    var alertRules: [PriceAlertRule]
    var refreshInterval: TimeInterval

    static let defaults = AppSettings(
        assets: [.btc],
        alertRules: [],
        refreshInterval: 15
    )
}

final class SettingsStore {
    private enum Key {
        static let asset = "asset"
        static let assets = "assets"
        static let alertRules = "alertRules"
        static let lowerThreshold = "lowerThreshold"
        static let upperThreshold = "upperThreshold"
        static let refreshInterval = "refreshInterval"
    }

    private let defaults = UserDefaults.standard

    func load() -> AppSettings {
        let storedAssets = defaults.stringArray(forKey: Key.assets)?
            .compactMap(TrackedAsset.init(rawValue:))
        let legacyAsset = defaults.string(forKey: Key.asset).flatMap(TrackedAsset.init(rawValue:))
        let assets = normalizedAssets(storedAssets ?? legacyAsset.map { [$0] } ?? AppSettings.defaults.assets)
        let lower = optionalDouble(forKey: Key.lowerThreshold)
        let upper = optionalDouble(forKey: Key.upperThreshold)
        let alertRules = loadAlertRules() ?? legacyAlertRules(assets: assets, lower: lower, upper: upper)
        let interval = defaults.double(forKey: Key.refreshInterval)

        return AppSettings(
            assets: assets,
            alertRules: alertRules,
            refreshInterval: interval >= 5 ? interval : AppSettings.defaults.refreshInterval
        )
    }

    func save(_ settings: AppSettings) {
        let assets = normalizedAssets(settings.assets)
        defaults.set(assets.map(\.rawValue), forKey: Key.assets)
        defaults.set(assets.first?.rawValue, forKey: Key.asset)
        saveAlertRules(settings.alertRules)
        defaults.set(settings.refreshInterval, forKey: Key.refreshInterval)
    }

    private func normalizedAssets(_ assets: [TrackedAsset]) -> [TrackedAsset] {
        let unique = TrackedAsset.allCases.filter { assets.contains($0) }
        return Array((unique.isEmpty ? AppSettings.defaults.assets : unique).prefix(2))
    }

    private func optionalDouble(forKey key: String) -> Double? {
        guard defaults.object(forKey: key) != nil else {
            return nil
        }
        return defaults.double(forKey: key)
    }

    private func loadAlertRules() -> [PriceAlertRule]? {
        guard let data = defaults.data(forKey: Key.alertRules) else {
            return nil
        }
        return try? JSONDecoder().decode([PriceAlertRule].self, from: data)
    }

    private func saveAlertRules(_ rules: [PriceAlertRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: Key.alertRules)
        }
    }

    private func legacyAlertRules(assets: [TrackedAsset], lower: Double?, upper: Double?) -> [PriceAlertRule] {
        var rules: [PriceAlertRule] = []
        for asset in assets {
            if let lower {
                rules.append(PriceAlertRule(asset: asset, direction: .belowOrEqual, threshold: lower))
            }
            if let upper {
                rules.append(PriceAlertRule(asset: asset, direction: .aboveOrEqual, threshold: upper))
            }
        }
        return rules
    }
}

final class PriceService {
    enum PriceError: Error, LocalizedError {
        case badURL
        case missingPrice
        case allSourcesFailed(String)

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "Bad request URL"
            case .missingPrice:
                return "Missing price in response"
            case .allSourcesFailed(let details):
                return details.isEmpty ? "All price sources failed" : details
            }
        }
    }

    private let session: URLSession
    private let providers: [PriceProvider]

    init(session: URLSession = .shared) {
        self.session = session
        self.providers = [
            GatePriceProvider(session: session),
            OKXPriceProvider(session: session),
            MEXCPriceProvider(session: session),
            BinancePriceProvider(session: session)
        ]
    }

    func fetchPrice(for asset: TrackedAsset) async throws -> PriceQuote {
        var failures: [String] = []
        for provider in providers {
            let startedAt = Date()
            AppLog.write("price.start asset=\(asset.displayName) provider=\(provider.name)")
            do {
                let price = try await provider.fetchPrice(for: asset)
                let elapsed = Date().timeIntervalSince(startedAt)
                AppLog.write("price.success asset=\(asset.displayName) provider=\(provider.name) price=\(price) elapsed=\(String(format: "%.3f", elapsed))s")
                return PriceQuote(price: price, source: provider.name)
            } catch {
                let description = describe(error)
                let elapsed = Date().timeIntervalSince(startedAt)
                AppLog.write("price.failure asset=\(asset.displayName) provider=\(provider.name) error=\(description) elapsed=\(String(format: "%.3f", elapsed))s")
                failures.append("\(provider.name): \(description)")
            }
        }
        throw PriceError.allSourcesFailed(failures.joined(separator: "; "))
    }

    private func describe(_ error: Error) -> String {
        ErrorDescription.describe(error)
    }
}

protocol PriceProvider {
    var name: String { get }
    func fetchPrice(for asset: TrackedAsset) async throws -> Double
}

extension PriceProvider {
    func requestData(from url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw PriceService.PriceError.missingPrice
        }
        return data
    }

    func symbol(for asset: TrackedAsset) -> String {
        asset.rawValue
    }

    func instrumentId(for asset: TrackedAsset) -> String {
        switch asset {
        case .btc:
            return "BTC-USDT"
        case .eth:
            return "ETH-USDT"
        case .bnb:
            return "BNB-USDT"
        case .sol:
            return "SOL-USDT"
        }
    }

    func currencyPair(for asset: TrackedAsset) -> String {
        switch asset {
        case .btc:
            return "BTC_USDT"
        case .eth:
            return "ETH_USDT"
        case .bnb:
            return "BNB_USDT"
        case .sol:
            return "SOL_USDT"
        }
    }
}

final class OKXPriceProvider: PriceProvider {
    let name = "OKX"
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func fetchPrice(for asset: TrackedAsset) async throws -> Double {
        var components = URLComponents(string: "https://www.okx.com/api/v5/market/ticker")
        components?.queryItems = [URLQueryItem(name: "instId", value: instrumentId(for: asset))]

        guard let url = components?.url else {
            throw PriceService.PriceError.badURL
        }

        let data = try await requestData(from: url, session: session)
        let ticker = try JSONDecoder().decode(OKXTickerResponse.self, from: data)

        let expectedInstId = instrumentId(for: asset)
        guard
            let item = ticker.data.first(where: { $0.instId == expectedInstId }),
            let price = Double(item.last)
        else {
            throw PriceService.PriceError.missingPrice
        }
        return price
    }
}

final class MEXCPriceProvider: PriceProvider {
    let name = "MEXC"
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func fetchPrice(for asset: TrackedAsset) async throws -> Double {
        var components = URLComponents(string: "https://api.mexc.com/api/v3/ticker/price")
        components?.queryItems = [URLQueryItem(name: "symbol", value: asset.rawValue)]

        guard let url = components?.url else {
            throw PriceService.PriceError.badURL
        }

        let data = try await requestData(from: url, session: session)
        let ticker = try JSONDecoder().decode(MEXCTickerResponse.self, from: data)

        guard ticker.symbol == symbol(for: asset), let price = Double(ticker.price) else {
            throw PriceService.PriceError.missingPrice
        }
        return price
    }
}

final class GatePriceProvider: PriceProvider {
    let name = "Gate"
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func fetchPrice(for asset: TrackedAsset) async throws -> Double {
        var components = URLComponents(string: "https://api.gateio.ws/api/v4/spot/tickers")
        components?.queryItems = [URLQueryItem(name: "currency_pair", value: currencyPair(for: asset))]

        guard let url = components?.url else {
            throw PriceService.PriceError.badURL
        }

        let data = try await requestData(from: url, session: session)
        let tickers = try JSONDecoder().decode([GateTickerResponse].self, from: data)

        let expectedPair = currencyPair(for: asset)
        guard
            let ticker = tickers.first(where: { $0.currencyPair == expectedPair }),
            let price = Double(ticker.last)
        else {
            throw PriceService.PriceError.missingPrice
        }
        return price
    }
}

final class BinancePriceProvider: PriceProvider {
    let name = "Binance"
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func fetchPrice(for asset: TrackedAsset) async throws -> Double {
        var components = URLComponents(string: "https://api.binance.com/api/v3/ticker/price")
        components?.queryItems = [URLQueryItem(name: "symbol", value: asset.rawValue)]

        guard let url = components?.url else {
            throw PriceService.PriceError.badURL
        }

        let data = try await requestData(from: url, session: session)
        let ticker = try JSONDecoder().decode(TickerResponse.self, from: data)

        guard ticker.symbol == symbol(for: asset), let price = Double(ticker.price) else {
            throw PriceService.PriceError.missingPrice
        }
        return price
    }
}

final class AlertState {
    private var lastTriggered: [String: Date] = [:]
    private let cooldown: TimeInterval = 300

    func shouldTrigger(key: String) -> Bool {
        let now = Date()
        if let last = lastTriggered[key], now.timeIntervalSince(last) < cooldown {
            return false
        }
        lastTriggered[key] = now
        return true
    }

    func reset() {
        lastTriggered.removeAll()
    }
}

final class NotificationSender {
    func requestAuthorizationIfNeeded() {
        guard hasAppBundle else {
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(title: String, body: String) {
        if hasAppBundle {
            sendUserNotification(title: title, body: body)
            return
        }

        if sendAppleScriptNotification(title: title, body: body) {
            return
        }
        sendLegacyNotification(title: title, body: body)
    }

    private var hasAppBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    private func sendUserNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "crypto-ticker-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if error != nil {
                self?.sendLegacyNotification(title: title, body: body)
            }
        }
    }

    private func sendAppleScriptNotification(title: String, body: String) -> Bool {
        let script = """
        display notification "\(escapeAppleScript(body))" with title "\(escapeAppleScript(title))" sound name "default"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func sendLegacyNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func escapeAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

final class AlertRuleRow: NSObject {
    let view: NSStackView
    private let assetPopup = NSPopUpButton()
    private let directionPopup = NSPopUpButton()
    private let thresholdField = NSTextField()
    private let onRemove: (AlertRuleRow) -> Void

    init(rule: PriceAlertRule, blankThreshold: Bool = false, onRemove: @escaping (AlertRuleRow) -> Void) {
        self.onRemove = onRemove
        self.view = NSStackView()

        super.init()

        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 8
        view.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true

        for asset in TrackedAsset.allCases {
            assetPopup.addItem(withTitle: asset.displayName)
        }
        assetPopup.selectItem(withTitle: rule.asset.displayName)
        assetPopup.widthAnchor.constraint(equalToConstant: 90).isActive = true

        for direction in AlertDirection.allCases {
            directionPopup.addItem(withTitle: direction.displayName)
        }
        directionPopup.selectItem(withTitle: rule.direction.displayName)
        directionPopup.widthAnchor.constraint(equalToConstant: 64).isActive = true

        thresholdField.placeholderString = "Price"
        thresholdField.stringValue = blankThreshold ? "" : formatPlain(rule.threshold)
        thresholdField.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let removeButton = NSButton(title: "Delete", target: self, action: #selector(remove))
        removeButton.bezelStyle = .rounded
        removeButton.widthAnchor.constraint(equalToConstant: 64).isActive = true

        view.addArrangedSubview(assetPopup)
        view.addArrangedSubview(directionPopup)
        view.addArrangedSubview(thresholdField)
        view.addArrangedSubview(removeButton)
    }

    var rule: PriceAlertRule? {
        guard
            let assetTitle = assetPopup.titleOfSelectedItem,
            let asset = TrackedAsset.allCases.first(where: { $0.displayName == assetTitle }),
            let directionTitle = directionPopup.titleOfSelectedItem,
            let direction = AlertDirection.allCases.first(where: { $0.displayName == directionTitle }),
            let threshold = parseOptionalDouble(thresholdField.stringValue)
        else {
            return nil
        }

        return PriceAlertRule(asset: asset, direction: direction, threshold: threshold)
    }

    @objc private func remove() {
        onRemove(self)
    }

    private func parseOptionalDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return Double(trimmed)
    }

    private func formatPlain(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ""
        formatter.maximumFractionDigits = 8
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

final class SettingsWindowController: NSWindowController {
    private let firstAssetPopup = NSPopUpButton()
    private let secondAssetPopup = NSPopUpButton()
    private let intervalField = NSTextField()
    private let alertsStack = NSStackView()
    private let alertsScrollView = NSScrollView()
    private let emptyAlertsLabel = NSTextField(labelWithString: "No alerts configured")
    private var alertRows: [AlertRuleRow] = []
    private let onSave: (AppSettings) -> Void
    private var settings: AppSettings

    init(settings: AppSettings, onSave: @escaping (AppSettings) -> Void) {
        self.settings = settings
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Crypto Ticker Settings"
        window.isReleasedWhenClosed = false

        super.init(window: window)
        buildUI()
        apply(settings: settings)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -18)
        ])

        intervalField.placeholderString = "Refresh seconds, min 5"

        configureAssetPopup(firstAssetPopup, allowsNone: false)
        configureAssetPopup(secondAssetPopup, allowsNone: true)

        stack.addArrangedSubview(menuBarAssetsRow())
        stack.addArrangedSubview(row(label: "Refresh", control: intervalField))
        stack.addArrangedSubview(alertHeaderRow())

        alertsStack.orientation = .vertical
        alertsStack.alignment = .leading
        alertsStack.spacing = 8
        alertsStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        alertsStack.translatesAutoresizingMaskIntoConstraints = false

        emptyAlertsLabel.textColor = .secondaryLabelColor
        emptyAlertsLabel.alignment = .center
        emptyAlertsLabel.translatesAutoresizingMaskIntoConstraints = false

        alertsScrollView.borderType = .lineBorder
        alertsScrollView.hasVerticalScroller = true
        alertsScrollView.autohidesScrollers = false
        alertsScrollView.drawsBackground = false
        alertsScrollView.translatesAutoresizingMaskIntoConstraints = false
        alertsScrollView.documentView = alertsStack
        alertsScrollView.addSubview(emptyAlertsLabel)

        NSLayoutConstraint.activate([
            alertsScrollView.heightAnchor.constraint(equalToConstant: 132),
            alertsStack.widthAnchor.constraint(equalTo: alertsScrollView.contentView.widthAnchor),
            alertsStack.topAnchor.constraint(equalTo: alertsScrollView.contentView.topAnchor),
            emptyAlertsLabel.centerXAnchor.constraint(equalTo: alertsScrollView.centerXAnchor),
            emptyAlertsLabel.centerYAnchor.constraint(equalTo: alertsScrollView.centerYAnchor)
        ])
        stack.addArrangedSubview(alertsScrollView)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded

        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(cancelButton)
        buttons.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttons)
    }

    private func row(label: String, control: NSControl) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.widthAnchor.constraint(equalToConstant: 120).isActive = true

        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true

        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func menuBarAssetsRow() -> NSStackView {
        let labelView = NSTextField(labelWithString: "Menu bar")
        labelView.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let popupStack = NSStackView(views: [
            popupGroup(label: "Slot 1", popup: firstAssetPopup),
            popupGroup(label: "Slot 2", popup: secondAssetPopup)
        ])
        popupStack.orientation = .horizontal
        popupStack.alignment = .centerY
        popupStack.spacing = 14

        let row = NSStackView(views: [labelView, popupStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func popupGroup(label: String, popup: NSPopUpButton) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.textColor = .secondaryLabelColor
        labelView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let group = NSStackView(views: [labelView, popup])
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = 6
        return group
    }

    private func alertHeaderRow() -> NSStackView {
        let labelView = NSTextField(labelWithString: "Alerts")
        labelView.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let addButton = NSButton(title: "+", target: self, action: #selector(addAlert))
        addButton.bezelStyle = .rounded
        addButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let row = NSStackView(views: [labelView, addButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func apply(settings: AppSettings) {
        firstAssetPopup.selectItem(withTitle: settings.assets.first?.displayName ?? AppSettings.defaults.assets[0].displayName)
        if let second = settings.assets.dropFirst().first {
            secondAssetPopup.selectItem(withTitle: second.displayName)
        } else {
            secondAssetPopup.selectItem(withTitle: "None")
        }
        intervalField.stringValue = formatPlain(settings.refreshInterval)

        for rule in settings.alertRules {
            addAlertRow(rule: rule)
        }
        updateEmptyAlertsState()
    }

    @objc private func save() {
        let next = AppSettings(
            assets: selectedAssets(),
            alertRules: alertRows.compactMap(\.rule),
            refreshInterval: max(parseOptionalDouble(intervalField.stringValue) ?? 15, 5)
        )

        settings = next
        onSave(next)
        window?.close()
    }

    @objc private func addAlert() {
        let asset = selectedAssets().first ?? AppSettings.defaults.assets[0]
        addAlertRow(rule: PriceAlertRule(asset: asset, direction: .belowOrEqual, threshold: 0), blankThreshold: true)
    }

    @objc private func cancel() {
        window?.close()
    }

    private func parseOptionalDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return Double(trimmed)
    }

    private func selectedAssets() -> [TrackedAsset] {
        let selected = [selectedAsset(from: firstAssetPopup), selectedAsset(from: secondAssetPopup)].compactMap { $0 }
        let unique = TrackedAsset.allCases.filter { selected.contains($0) }
        return unique.isEmpty ? AppSettings.defaults.assets : unique
    }

    private func selectedAsset(from popup: NSPopUpButton) -> TrackedAsset? {
        guard let title = popup.titleOfSelectedItem, title != "None" else {
            return nil
        }
        return TrackedAsset.allCases.first { $0.displayName == title }
    }

    private func configureAssetPopup(_ popup: NSPopUpButton, allowsNone: Bool) {
        if allowsNone {
            popup.addItem(withTitle: "None")
        }
        for asset in TrackedAsset.allCases {
            popup.addItem(withTitle: asset.displayName)
        }
        popup.widthAnchor.constraint(equalToConstant: 120).isActive = true
    }

    private func addAlertRow(rule: PriceAlertRule, blankThreshold: Bool = false) {
        let row = AlertRuleRow(rule: rule, blankThreshold: blankThreshold) { [weak self] row in
            self?.removeAlertRow(row)
        }
        alertRows.append(row)
        alertsStack.addArrangedSubview(row.view)
        alertsScrollView.contentView.scroll(to: .zero)
        updateEmptyAlertsState()
    }

    private func removeAlertRow(_ row: AlertRuleRow) {
        alertRows.removeAll { $0 === row }
        alertsStack.removeArrangedSubview(row.view)
        row.view.removeFromSuperview()
        updateEmptyAlertsState()
    }

    private func updateEmptyAlertsState() {
        emptyAlertsLabel.isHidden = !alertRows.isEmpty
    }

    private func formatPlain(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ""
        formatter.maximumFractionDigits = 8
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSUserNotificationCenterDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settingsStore = SettingsStore()
    private let priceService = PriceService()
    private let alertState = AlertState()
    private let notificationSender = NotificationSender()

    private var settings = AppSettings.defaults
    private var timer: Timer?
    private var latestPrices: [TrackedAsset: Double] = [:]
    private var latestSources: [TrackedAsset: String] = [:]
    private var latestErrors: [TrackedAsset: String] = [:]
    private var isFetching = false
    private var alertStatusResetWorkItem: DispatchWorkItem?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSUserNotificationCenter.default.delegate = self
        UNUserNotificationCenter.current().delegate = self
        notificationSender.requestAuthorizationIfNeeded()
        settings = settingsStore.load()
        AppLog.write("app.launch assets=\(settings.assets.map(\.displayName).joined(separator: ",")) refresh=\(settings.refreshInterval)")
        configureMenu()
        updateStatusTitle("Loading")
        schedulePolling()
        fetchNow()
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Fetch Now", action: #selector(fetchNowFromMenu), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Test Notification", action: #selector(testNotification), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func schedulePolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            self?.fetchNow()
        }
        timer?.tolerance = max(settings.refreshInterval * 0.2, 1)
    }

    @objc private func fetchNowFromMenu() {
        fetchNow()
    }

    @objc private func testNotification() {
        notificationSender.send(
            title: "CryptoTickerBar test",
            body: "System notification is working."
        )
        showAlertStatus()
    }

    private func fetchNow() {
        guard !isFetching else {
            AppLog.write("fetch.skip reason=in_progress")
            return
        }
        isFetching = true
        let assets = monitoredAssets()
        let priceService = self.priceService
        AppLog.write("fetch.begin assets=\(assets.map(\.displayName).joined(separator: ","))")

        Task<Void, Never> { [weak self] in
            let completedResults = await Self.fetchPrices(for: assets, priceService: priceService)
            guard let appDelegate = self else {
                return
            }
            await MainActor.run {
                appDelegate.applyFetchResults(completedResults)
            }
        }
    }

    private static func fetchPrices(for assets: [TrackedAsset], priceService: PriceService) async -> [AssetFetchResult] {
        var results: [AssetFetchResult] = []
        for asset in assets {
            do {
                let quote = try await priceService.fetchPrice(for: asset)
                let result = AssetFetchResult(
                    rawAsset: asset.rawValue,
                    price: quote.price,
                    source: quote.source,
                    errorMessage: nil
                )
                AppLog.write("fetch.collect rawAsset=\(result.rawAsset) price=\(String(quote.price)) error=")
                results.append(result)
            } catch {
                let errorMessage = ErrorDescription.describe(error)
                let result = AssetFetchResult(
                    rawAsset: asset.rawValue,
                    price: nil,
                    source: nil,
                    errorMessage: errorMessage
                )
                AppLog.write("fetch.collect rawAsset=\(result.rawAsset) price=nil error=\(errorMessage)")
                results.append(result)
            }
        }
        return results
    }

    private func applyFetchResults(_ results: [AssetFetchResult]) {
        for result in results {
            let rawAsset = result.rawAsset
            guard let asset = TrackedAsset(rawValue: rawAsset) else {
                AppLog.write("fetch.result.skip rawAsset=\(rawAsset) reason=unknown_asset")
                continue
            }
            let priceText = result.price.map { String($0) } ?? "nil"
            let errorText = result.errorMessage ?? ""
            AppLog.write("fetch.result asset=\(asset.displayName) rawAsset=\(rawAsset) price=\(priceText) error=\(errorText)")
            if let price = result.price, let source = result.source {
                latestPrices[asset] = price
                latestSources[asset] = source
                latestErrors.removeValue(forKey: asset)
                evaluateAlerts(asset: asset, price: price)
            } else {
                latestPrices.removeValue(forKey: asset)
                latestSources.removeValue(forKey: asset)
                latestErrors[asset] = result.errorMessage ?? "Unknown price error"
            }
        }
        isFetching = false
        let title = statusText()
        AppLog.write("fetch.end title=\(title) prices=\(latestPrices.map { "\($0.key.displayName)=\($0.value)" }.joined(separator: ",")) errors=\(latestErrors.map { "\($0.key.displayName)=\($0.value)" }.joined(separator: " | "))")
        updateStatusTitle(title)
    }

    private func evaluateAlerts(asset: TrackedAsset, price: Double) {
        for rule in settings.alertRules where rule.asset == asset {
            switch rule.direction {
            case .belowOrEqual where price <= rule.threshold:
                sendAlert(
                    key: rule.key,
                    asset: asset,
                    title: "\(asset.displayName) price below threshold",
                    body: "\(formatPrice(price)) USDT <= \(formatPrice(rule.threshold)) USDT"
                )
            case .aboveOrEqual where price >= rule.threshold:
                sendAlert(
                    key: rule.key,
                    asset: asset,
                    title: "\(asset.displayName) price above threshold",
                    body: "\(formatPrice(price)) USDT >= \(formatPrice(rule.threshold)) USDT"
                )
            default:
                break
            }
        }
    }

    private func sendAlert(key: String, asset: TrackedAsset, title: String, body: String) {
        guard alertState.shouldTrigger(key: key) else {
            return
        }

        notificationSender.send(title: title, body: body)
        showAlertStatus(asset: asset)
    }

    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        shouldPresent notification: NSUserNotification
    ) -> Bool {
        true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    private func showAlertStatus() {
        showAlertStatus(asset: nil)
    }

    private func showAlertStatus(asset: TrackedAsset?) {
        alertStatusResetWorkItem?.cancel()
        updateStatusTitle("ALERT \(asset?.displayName ?? settings.assets.map(\.displayName).joined(separator: " "))")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            updateStatusTitle(statusText())
        }
        alertStatusResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    @objc private func openSettings() {
        settingsWindowController = SettingsWindowController(settings: settings) { [weak self] next in
            guard let self else {
                return
            }
            self.settings = next
            AppLog.write("settings.save assets=\(next.assets.map(\.displayName).joined(separator: ",")) refresh=\(next.refreshInterval)")
            self.settingsStore.save(next)
            let monitored = self.monitoredAssets(settings: next)
            self.latestPrices = self.latestPrices.filter { monitored.contains($0.key) }
            self.latestSources = self.latestSources.filter { monitored.contains($0.key) }
            self.latestErrors = self.latestErrors.filter { monitored.contains($0.key) }
            self.alertState.reset()
            self.schedulePolling()
            self.fetchNow()
        }

        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateStatusTitle(_ title: String) {
        statusItem.button?.title = title
        statusItem.button?.toolTip = tooltipText()
    }

    private func tooltipText() -> String {
        var lines = ["Crypto Ticker Bar"]
        lines.append("Assets: \(settings.assets.map { "\($0.displayName)/USDT" }.joined(separator: ", "))")
        for asset in settings.assets {
            if let price = latestPrices[asset] {
                lines.append("\(asset.displayName): \(formatPrice(price))")
            }
            if let source = latestSources[asset] {
                lines.append("\(asset.displayName) source: \(source)")
            }
            if let error = latestErrors[asset] {
                lines.append("\(asset.displayName) error: \(error)")
            }
        }
        for rule in settings.alertRules {
            lines.append("Alert: \(rule.asset.displayName) \(rule.direction.displayName) \(formatPrice(rule.threshold))")
        }
        lines.append("Refresh: \(Int(settings.refreshInterval))s")
        return lines.joined(separator: "\n")
    }

    private func statusText() -> String {
        settings.assets.map { asset in
            if let price = latestPrices[asset] {
                return "\(asset.displayName) \(compactPrice(price))"
            }
            return "\(asset.displayName) --"
        }.joined(separator: " | ")
    }

    private func monitoredAssets(settings: AppSettings? = nil) -> [TrackedAsset] {
        let settings = settings ?? self.settings
        let selected = settings.assets + settings.alertRules.map(\.asset)
        return TrackedAsset.allCases.filter { selected.contains($0) }
    }

    private func compactPrice(_ price: Double) -> String {
        if price >= 1_000 {
            return NumberFormatter.compact.string(from: NSNumber(value: price)) ?? formatPrice(price)
        }
        return formatPrice(price)
    }

    private func formatPrice(_ price: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = price >= 100 ? 2 : 4
        formatter.maximumFractionDigits = price >= 100 ? 2 : 6
        return formatter.string(from: NSNumber(value: price)) ?? "\(price)"
    }
}

private extension NumberFormatter {
    static let compact: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

@main
enum CryptoTickerBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
