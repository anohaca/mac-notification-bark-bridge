import Foundation
import Testing
@testable import MacNotificationBarkBridge

@Test func configurationStoreCreatesTemplateAndLoadsResolvedConfiguration() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    let store = ConfigurationStore(
        configurationDirectoryProvider: { rootURL },
        templateDataProvider: {
            """
            {
              "deviceKey": "abc123",
              "barkBaseURL": "https://api.day.app",
              "sourceFilter": "Messages",
              "pollInterval": 5,
              "dedupeWindow": 90,
              "dryRun": true,
              "promptForAccessibility": false,
              "launchAtLogin": true
            }
            """.data(using: .utf8)!
        }
    )

    let fileURL = try store.ensureConfigurationFileExists()
    let configuration = try store.load()

    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    #expect(configuration.deviceKey == "abc123")
    #expect(configuration.sourceFilter == "Messages")
    #expect(configuration.pollInterval == 5)
    #expect(configuration.dedupeWindow == 90)
    #expect(configuration.dryRun == true)
    #expect(configuration.promptForAccessibility == false)
    #expect(configuration.launchAtLogin == true)
}

@Test func configurationStoreSavesAndLoadsEditableConfiguration() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    let store = ConfigurationStore(
        configurationDirectoryProvider: { rootURL },
        templateDataProvider: {
            try JSONEncoder().encode(StoredConfiguration.defaults)
        }
    )

    let stored = StoredConfiguration(
        deviceKey: "",
        barkBaseURL: "https://api.day.app",
        sourceFilter: "Mail",
        pollInterval: 4,
        dryRun: true,
        promptForAccessibility: false,
        dedupeWindow: 120,
        launchAtLogin: true
    )

    try store.save(stored)
    let loaded = try store.loadStoredConfiguration()

    #expect(loaded.deviceKey == "")
    #expect(loaded.sourceFilter == "Mail")
    #expect(loaded.pollInterval == 4)
    #expect(loaded.dryRun == true)
    #expect(loaded.promptForAccessibility == false)
    #expect(loaded.dedupeWindow == 120)
    #expect(loaded.launchAtLogin == true)
}

@Test func oldConfigurationDefaultsLaunchAtLoginToFalse() throws {
    let data = """
    {
      "deviceKey": "abc123",
      "barkBaseURL": "https://api.day.app"
    }
    """.data(using: .utf8)!

    let stored = try JSONDecoder().decode(StoredConfiguration.self, from: data).normalized()
    #expect(stored.launchAtLogin == false)
}
