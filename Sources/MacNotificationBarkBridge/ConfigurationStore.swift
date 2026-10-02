import Foundation

struct StoredConfiguration: Codable, Equatable, Sendable {
    var deviceKey: String?
    var barkBaseURL: String?
    var sourceFilter: String?
    var pollInterval: Double?
    var dryRun: Bool?
    var promptForAccessibility: Bool?
    var dedupeWindow: Double?
    var launchAtLogin: Bool?

    static let defaults = StoredConfiguration(
        deviceKey: "",
        barkBaseURL: "https://api.day.app",
        sourceFilter: nil,
        pollInterval: 2,
        dryRun: false,
        promptForAccessibility: true,
        dedupeWindow: 300,
        launchAtLogin: false
    )

    func normalized() -> StoredConfiguration {
        StoredConfiguration(
            deviceKey: deviceKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            barkBaseURL: barkBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? Self.defaults.barkBaseURL,
            sourceFilter: sourceFilter?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            pollInterval: pollInterval ?? Self.defaults.pollInterval,
            dryRun: dryRun ?? Self.defaults.dryRun,
            promptForAccessibility: promptForAccessibility ?? Self.defaults.promptForAccessibility,
            dedupeWindow: dedupeWindow ?? Self.defaults.dedupeWindow,
            launchAtLogin: launchAtLogin ?? Self.defaults.launchAtLogin
        )
    }

    func validateForPersistence() throws {
        let normalized = normalized()

        if let baseURL = normalized.barkBaseURL,
           URL(string: baseURL) == nil {
            throw BridgeError.invalidFieldValue(
                field: "Bark 服务地址",
                reason: "请输入有效的 URL。"
            )
        }

        if let pollInterval = normalized.pollInterval,
           pollInterval <= 0 {
            throw BridgeError.invalidFieldValue(
                field: "轮询间隔",
                reason: "请输入大于 0 的值。"
            )
        }

        if let dedupeWindow = normalized.dedupeWindow,
           dedupeWindow <= 0 {
            throw BridgeError.invalidFieldValue(
                field: "去重窗口",
                reason: "请输入大于 0 的值。"
            )
        }
    }

    func resolved() throws -> AppConfiguration {
        let normalized = normalized()
        let trimmedDeviceKey = normalized.deviceKey ?? ""
        guard !trimmedDeviceKey.isEmpty else {
            throw BridgeError.missingDeviceKey
        }

        let baseURLString = normalized.barkBaseURL ?? "https://api.day.app"
        guard let barkURL = URL(string: baseURLString) else {
            throw BridgeError.invalidBarkBaseURL(baseURLString)
        }

        let interval = normalized.pollInterval ?? 2
        guard interval > 0 else {
            throw BridgeError.invalidPollInterval(String(interval))
        }

        let dedupe = normalized.dedupeWindow ?? 300
        guard dedupe > 0 else {
            throw BridgeError.invalidPollInterval(String(dedupe))
        }

        return AppConfiguration(
            deviceKey: trimmedDeviceKey,
            barkBaseURL: barkURL,
            sourceFilter: normalized.sourceFilter,
            pollInterval: interval,
            dryRun: normalized.dryRun ?? false,
            runOnce: false,
            dumpTree: false,
            fixturePath: nil,
            promptForAccessibility: normalized.promptForAccessibility ?? true,
            dedupeWindow: dedupe,
            launchAtLogin: normalized.launchAtLogin ?? false
        )
    }
}

struct ConfigurationStore {
    let configurationDirectoryProvider: () throws -> URL
    let templateDataProvider: () throws -> Data

    init(
        configurationDirectoryProvider: @escaping () throws -> URL = Self.defaultConfigurationDirectory,
        templateDataProvider: @escaping () throws -> Data = Self.bundledTemplateData
    ) {
        self.configurationDirectoryProvider = configurationDirectoryProvider
        self.templateDataProvider = templateDataProvider
    }

    func configurationDirectoryURL() throws -> URL {
        try configurationDirectoryProvider()
    }

    func configurationURL() throws -> URL {
        try configurationDirectoryURL()
            .appendingPathComponent("config.json", isDirectory: false)
    }

    @discardableResult
    func ensureConfigurationFileExists() throws -> URL {
        let directoryURL = try configurationDirectoryURL()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let fileURL = directoryURL.appendingPathComponent("config.json", isDirectory: false)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            return fileURL
        }

        try templateDataProvider().write(to: fileURL, options: .atomic)
        return fileURL
    }

    func load() throws -> AppConfiguration {
        try loadStoredConfiguration().resolved()
    }

    func loadStoredConfiguration() throws -> StoredConfiguration {
        let fileURL = try ensureConfigurationFileExists()

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(StoredConfiguration.self, from: data)
        } catch let error as BridgeError {
            throw error
        } catch {
            throw BridgeError.invalidConfigurationFile(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }

    func save(_ storedConfiguration: StoredConfiguration) throws {
        let normalized = storedConfiguration.normalized()
        try normalized.validateForPersistence()

        let fileURL = try ensureConfigurationFileExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized)
        try data.write(to: fileURL, options: .atomic)
    }

    static func defaultConfigurationDirectory() throws -> URL {
        guard let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw BridgeError.invalidConfigurationFile(
                path: "~",
                reason: "Unable to resolve Application Support directory."
            )
        }

        return baseURL.appendingPathComponent("MacNotificationBarkBridge", isDirectory: true)
    }

    static func bundledTemplateData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "config.template",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            throw BridgeError.missingBundledTemplate
        }
        return try Data(contentsOf: url)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
