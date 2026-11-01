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
        dedupeWindow: 300,
        launchAtLogin: false
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
        dedupeWindow: 300,
        launchAtLogin: false
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

@Test func bridgeServiceRetriesUnknownTimeWhileNotificationCenterIsOpen() async throws {
    let initial = notificationPanelTree(timestampTestCard(time: nil))
    let resolved = notificationPanelTree(timestampTestCard(time: "3分钟前"))
    let snapshots = SnapshotSequence([initial, resolved])
    let configuration = try AppConfiguration.parse(
        arguments: ["bridge", "--device-key", "test", "--dry-run"],
        environment: [:]
    )
    let logger = TestLogger()
    let client = BarkClient(baseURL: configuration.barkBaseURL, deviceKey: "test", sender: { _ in
        Issue.record("Dry-run must not send Bark")
        throw URLError(.badServerResponse)
    })
    var service = BridgeService(
        configuration: configuration,
        snapshotProvider: SequencedSnapshotProvider(sequence: snapshots),
        barkClient: client,
        logger: logger
    )

    let delivered = try await service.runOnce()

    #expect(delivered.isEmpty)
    #expect(await snapshots.readCount == 2)
    let logs = await logger.messages()
    #expect(logs.contains { $0.contains("expired=1") && $0.contains("timeUnknown=0") })
    #expect(!logs.contains { $0.contains("scan.time_unknown action=forward") })
}

@Test func bridgeServiceStillForwardsTimeUnknownAfterBoundedRetry() async throws {
    let tree = notificationPanelTree(timestampTestCard(time: nil))
    let snapshots = SnapshotSequence([tree])
    let configuration = try AppConfiguration.parse(
        arguments: ["bridge", "--device-key", "test", "--dry-run"],
        environment: [:]
    )
    let client = BarkClient(baseURL: configuration.barkBaseURL, deviceKey: "test", sender: { _ in
        Issue.record("Dry-run must not send Bark")
        throw URLError(.badServerResponse)
    })
    var service = BridgeService(
        configuration: configuration,
        snapshotProvider: SequencedSnapshotProvider(sequence: snapshots),
        barkClient: client
    )

    let delivered = try await service.runOnce()

    #expect(delivered.map(\.title) == ["Old"])
    #expect(await snapshots.readCount == 3)
}

private func notificationPanelTree(_ card: AccessibilityNode) -> AccessibilityNode {
    AccessibilityNode(role: "AXApplication", children: [
        AccessibilityNode(role: "AXWindow", children: [card]),
    ])
}

private func timestampTestCard(time: String?) -> AccessibilityNode {
    AccessibilityNode(role: "AXGroup", subrole: "AXNotificationCenterBannerStack", nodeDescription: "Example，Old", children: [
        AccessibilityNode(role: "AXStaticText", value: "Old", identifier: "title"),
        AccessibilityNode(role: "AXStaticText", value: "Message body", identifier: "body"),
    ] + (time.map { [AccessibilityNode(role: "AXStaticText", value: $0)] } ?? []))
}

private actor SnapshotSequence {
    private let snapshots: [AccessibilityNode]
    private(set) var readCount = 0

    init(_ snapshots: [AccessibilityNode]) {
        self.snapshots = snapshots
    }

    func next() -> AccessibilityNode {
        let snapshot = snapshots[min(readCount, snapshots.count - 1)]
        readCount += 1
        return snapshot
    }
}

private struct SequencedSnapshotProvider: NotificationSnapshotProviding {
    let sequence: SnapshotSequence

    func snapshot() async throws -> AccessibilityNode {
        await sequence.next()
    }
}
