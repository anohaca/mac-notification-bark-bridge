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

actor SnapshotSequence {
    private let trees: [AccessibilityNode]
    private var index = 0

    init(trees: [AccessibilityNode]) {
        self.trees = trees
    }

    func next() -> AccessibilityNode {
        let current = trees[min(index, trees.count - 1)]
        index += 1
        return current
    }
}

struct SequenceSnapshotProvider: NotificationSnapshotProviding {
    let sequence: SnapshotSequence

    func snapshot() async throws -> AccessibilityNode {
        await sequence.next()
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

@Test func bridgeServiceBaselinesCardsWhenPanelOpens() async throws {
    let hiddenTree = AccessibilityNode(role: "AXApplication")
    let existingTree = notificationTree(
        [("Alice", "Existing notification", "card-1")]
    )
    let newNotificationTree = notificationTree(
        [
            ("Alice", "Existing notification", "card-1"),
            ("Bob", "New notification", "card-2"),
        ]
    )
    let sequence = SnapshotSequence(trees: [hiddenTree, existingTree, existingTree, newNotificationTree])
    let configuration = AppConfiguration(
        deviceKey: "test",
        barkBaseURL: URL(string: "https://api.day.app")!,
        sourceFilter: nil,
        pollInterval: 1,
        dryRun: true,
        runOnce: true,
        dumpTree: false,
        fixturePath: nil,
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
        snapshotProvider: SequenceSnapshotProvider(sequence: sequence),
        barkClient: barkClient,
        logger: logger
    )

    #expect(try await service.runOnce().isEmpty)
    #expect(try await service.runOnce().isEmpty)
    #expect(try await service.runOnce().isEmpty)
    let newNotifications = try await service.runOnce()

    #expect(newNotifications.count == 1)
    #expect(newNotifications.first?.title == "Bob")
    let messages = await logger.messages()
    #expect(messages.contains { $0.contains("scan.baseline panel_open matches=1 forwarded=0") })
}

private func notificationTree(_ records: [(String, String, String)]) -> AccessibilityNode {
    AccessibilityNode(
        role: "AXApplication",
        children: [
            AccessibilityNode(
                role: "AXWindow",
                title: "Notification Center",
                children: [
                    AccessibilityNode(
                        role: "AXGroup",
                        identifier: "notification-list",
                        children: records.map { title, body, identifier in
                            AccessibilityNode(
                                role: "AXGroup",
                                identifier: identifier,
                                children: [
                                    AccessibilityNode(role: "AXStaticText", value: "Messages"),
                                    AccessibilityNode(role: "AXStaticText", value: title),
                                    AccessibilityNode(role: "AXStaticText", value: body),
                                ]
                            )
                        }
                    ),
                ]
            ),
        ]
    )
}
