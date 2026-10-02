import Foundation
import Testing
@testable import MacNotificationBarkBridge

@MainActor
@Test func configurationWindowLoadsAndSavesFormValues() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    let store = ConfigurationStore(
        configurationDirectoryProvider: { rootURL },
        templateDataProvider: {
            try JSONEncoder().encode(StoredConfiguration.defaults)
        }
    )

    try store.save(
        StoredConfiguration(
            deviceKey: "initial-key",
            barkBaseURL: "https://api.day.app",
            sourceFilter: "Mail",
            pollInterval: 6,
            dryRun: true,
            promptForAccessibility: false,
            dedupeWindow: 180,
            launchAtLogin: true
        )
    )

    var didSave = false
    let controller = ConfigurationWindowController(
        configurationStore: store,
        onSave: { _ in didSave = true },
        onClose: {}
    )

    let loaded = try controller.currentFormConfiguration().normalized()
    #expect(loaded.deviceKey == "initial-key")
    #expect(loaded.sourceFilter == "Mail")
    #expect(loaded.pollInterval == 6)
    #expect(loaded.dryRun == true)
    #expect(loaded.launchAtLogin == true)

    controller.populateFields(
        with: StoredConfiguration(
            deviceKey: "updated-key",
            barkBaseURL: "https://example.com",
            sourceFilter: "Slack",
            pollInterval: 3,
            dryRun: false,
            promptForAccessibility: true,
            dedupeWindow: 45,
            launchAtLogin: false
        )
    )

    try controller.saveCurrentForm()

    let saved = try store.loadStoredConfiguration().normalized()
    #expect(didSave == true)
    #expect(saved.deviceKey == "updated-key")
    #expect(saved.barkBaseURL == "https://example.com")
    #expect(saved.sourceFilter == "Slack")
    #expect(saved.pollInterval == 3)
    #expect(saved.promptForAccessibility == true)
    #expect(saved.dedupeWindow == 45)
    #expect(saved.launchAtLogin == false)
    #expect(controller.statusTextForTesting.contains("已保存") == true)
}
