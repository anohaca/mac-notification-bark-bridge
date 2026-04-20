import Foundation
import Testing
@testable import MacNotificationBarkBridge

actor TestLogger: BridgeLogging {
    private(set) var entries: [String] = []

    func log(_ level: LogLevel, _ message: String) async {
        entries.append("[\(level.rawValue)] \(message)")
    }

    func storeSnapshot(_ root: AccessibilityNode) async {}

    func messages() -> [String] {
        entries
    }
}

@Test func bridgeServiceDryRunProcessesFixtureWithoutNetwork() async throws {
    let fixtureURL = try #require(Bundle.module.url(
        forResource: "sample-notification-tree",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))

    let configuration = AppConfiguration(
        deviceKey: "test",
        barkBaseURL: URL(string: "https://api.day.app")!,
        sourceFilter: "messages",
        pollInterval: 1,
        dryRun: true,
        runOnce: true,
        dumpTree: false,
        fixturePath: fixtureURL.path,
        promptForAccessibility: false,
        dedupeWindow: 300
    )

    let barkClient = BarkClient(
        baseURL: configuration.barkBaseURL,
        deviceKey: configuration.deviceKey,
        sender: { _ in
            Issue.record("dry-run path should not call Bark")
            let response = HTTPURLResponse(
                url: URL(string: "https://api.day.app/test")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
    )

    var service = BridgeService(
        configuration: configuration,
        snapshotProvider: FixtureSnapshotProvider(path: fixtureURL.path),
        barkClient: barkClient
    )

    let notifications = try await service.runOnce()
    #expect(notifications.count == 1)
}

@Test func bridgeServiceRedactsNotificationBodyInLogs() async throws {
    let fixtureURL = try #require(Bundle.module.url(
        forResource: "sample-notification-tree",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))

    let configuration = AppConfiguration(
        deviceKey: "test",
        barkBaseURL: URL(string: "https://api.day.app")!,
        sourceFilter: "messages",
        pollInterval: 1,
        dryRun: true,
        runOnce: true,
        dumpTree: false,
        fixturePath: fixtureURL.path,
        promptForAccessibility: false,
        dedupeWindow: 300
    )

    let logger = TestLogger()
    let barkClient = BarkClient(
        baseURL: configuration.barkBaseURL,
        deviceKey: configuration.deviceKey,
        sender: { _ in
            Issue.record("dry-run path should not call Bark")
            let response = HTTPURLResponse(
                url: URL(string: "https://api.day.app/test")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
    )

    var service = BridgeService(
        configuration: configuration,
        snapshotProvider: FixtureSnapshotProvider(path: fixtureURL.path),
        barkClient: barkClient,
        logger: logger
    )

    _ = try await service.runOnce()

    let messages = await logger.messages()
    let notificationLog = try #require(messages.first(where: { $0.contains("scan.notification") }))
    #expect(notificationLog.contains("source=Messages"))
    #expect(notificationLog.contains("title=Alice"))
    #expect(notificationLog.contains("bodyRedacted=true"))
    #expect(notificationLog.contains("Meet at 8 PM") == false)
    #expect(notificationLog.contains("Bring the tickets.") == false)
}
