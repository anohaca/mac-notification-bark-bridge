import Foundation
import Testing
@testable import MacNotificationBarkBridge

private let ageTestNow = Date(timeIntervalSince1970: 1_700_000_000)

@Test func notificationTimesParseChineseAndEnglishAndKeepClockRollover() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parser = NotificationTimeParser(calendar: calendar)
    for (label, seconds): (String, Double) in [
        ("刚刚", 0), ("Now", 0), ("30 秒前", 30), ("2分钟前", 120),
        ("3 minutes ago", 180), ("2h ago", 7200), ("1天前", 86400),
    ] {
        #expect(parser.date(from: label, now: ageTestNow) == ageTestNow.addingTimeInterval(-seconds))
    }
    let midnight = ISO8601DateFormatter().date(from: "2026-10-17T00:01:00Z")!
    #expect(parser.date(from: "23:59", now: midnight) == midnight.addingTimeInterval(-120))
    #expect(parser.date(from: "not a time", now: midnight) == nil)
    #expect(parser.date(from: "2026-10-16T23:59:00Z", now: midnight) == midnight.addingTimeInterval(-120))
    #expect(parser.date(from: "2026年10月16日 23:59", now: midnight) == midnight.addingTimeInterval(-120))
    #expect(parser.date(from: "昨天 下午11:59", now: midnight) == midnight.addingTimeInterval(-120))
}

@Test func notificationAgeAllowsBoundaryAndUnknownRejectsStaleAndFuture() {
    let policy = NotificationAgePolicy(maxAge: 120)
    #expect(policy.rejectionReason(timestamp: ageTestNow.addingTimeInterval(-120), now: ageTestNow) == nil)
    #expect(policy.rejectionReason(timestamp: ageTestNow.addingTimeInterval(-121), now: ageTestNow) == "expired")
    #expect(policy.rejectionReason(timestamp: nil, now: ageTestNow) == nil)
    #expect(policy.rejectionReason(timestamp: ageTestNow.addingTimeInterval(60), now: ageTestNow) == "time_in_future")
    #expect(NotificationAgePolicy(maxAge: 0).rejectionReason(timestamp: nil, now: ageTestNow) == nil)
}

@Test func parserPreservesCardTimeThroughNestedDuplicateAndDoesNotMixCards() throws {
    func card(title: String, time: String) -> AccessibilityNode {
        AccessibilityNode(role: "AXGroup", subrole: "AXNotificationCenterBanner", nodeDescription: "Example，\(title)", children: [
            AccessibilityNode(role: "AXGroup", children: [
                AccessibilityNode(role: "AXStaticText", value: title),
                AccessibilityNode(role: "AXStaticText", value: "Body for \(title)"),
            ]),
            AccessibilityNode(role: "AXDateTimeArea", value: time),
        ])
    }
    let tree = AccessibilityNode(role: "AXApplication", children: [
        AccessibilityNode(role: "AXWindow", children: [card(title: "Recent", time: "刚刚"), card(title: "Old", time: "3分钟前")]),
    ])
    let notifications = NotificationParser().parse(from: tree, sourceFilter: nil, now: ageTestNow)
    #expect(notifications.count == 2)
    #expect(notifications.first { $0.title == "Recent" }?.timestamp == ageTestNow)
    #expect(notifications.first { $0.title == "Old" }?.timestamp == ageTestNow.addingTimeInterval(-180))
    #expect(notifications.allSatisfy { !$0.body.contains("分钟前") && !$0.body.contains("刚刚") })
}

@Test func messageBodyTimePhrasesAreNotNotificationTimestamps() throws {
    let tree = AccessibilityNode(role: "AXGroup", subrole: "AXNotificationCenterBanner", nodeDescription: "Example，Title", children: [
        AccessibilityNode(role: "AXStaticText", value: "Title"),
        AccessibilityNode(role: "AXStaticText", value: "Body text"),
        AccessibilityNode(role: "AXStaticText", value: "1 minute ago"),
    ])
    let notification = try #require(NotificationParser().parse(from: tree, sourceFilter: nil, now: ageTestNow).first)
    #expect(notification.timestamp == nil)
    #expect(notification.body.contains("1 minute ago"))
    #expect(NotificationAgePolicy(maxAge: 120).rejectionReason(timestamp: notification.timestamp, now: ageTestNow) == nil)
}

@Test func identicalSiblingCardsDoNotShareTimestamps() throws {
    var unknown = ageCard("Same", time: nil)
    unknown.identifier = "unknown-card"
    var recent = ageCard("Same", time: "Now")
    recent.identifier = "recent-card"
    let tree = AccessibilityNode(role: "AXGroup", children: [unknown, recent])
    let notifications = NotificationParser().parse(from: tree, sourceFilter: nil, now: ageTestNow)
    #expect(notifications.count == 2)
    #expect(notifications.first { $0.identifier == "unknown-card" }?.timestamp == nil)
    #expect(notifications.first { $0.identifier == "recent-card" }?.timestamp == ageTestNow)
}

@Test func duplicateRepresentationsPreferKnownTimeOverUnknown() throws {
    let tree = AccessibilityNode(role: "AXApplication", children: [ageCard("Same", time: nil), ageCard("Same", time: "3分钟前")])
    let notifications = NotificationParser().parse(from: tree, sourceFilter: nil, now: ageTestNow)
    #expect(notifications.count == 1)
    let notification = try #require(notifications.first)
    #expect(notification.timestamp == ageTestNow.addingTimeInterval(-180))
    #expect(NotificationAgePolicy(maxAge: 120).rejectionReason(timestamp: notification.timestamp, now: ageTestNow) == "expired")
}

@Test func serviceFiltersStaleForwardsUnknownAndSupportsCustomAge() async throws {
    let tree = AccessibilityNode(role: "AXApplication", children: [
        ageCard("Fresh", time: "1分钟前"), ageCard("Old", time: "3分钟前"), ageCard("Unknown", time: nil),
    ])
    var configuration = try AppConfiguration.parse(arguments: ["bridge", "--device-key", "test", "--dry-run"], environment: [:])
    #expect(configuration.maxNotificationAge == 120)
    let logger = TestLogger()
    let client = BarkClient(baseURL: configuration.barkBaseURL, deviceKey: "test", sender: { _ in
        Issue.record("Dry-run must not send Bark")
        throw URLError(.badServerResponse)
    })
    var service = BridgeService(configuration: configuration, snapshotProvider: AgeTreeProvider(tree: tree), barkClient: client, logger: logger)
    let first = try await service.runOnce()
    #expect(first.map(\.title) == ["Fresh", "Unknown"])
    let logs = await logger.messages()
    #expect(logs.contains { $0.contains("expired=1") && $0.contains("timeUnknown=1") })
    #expect(logs.contains { $0.contains("scan.time_unknown action=forward") })

    configuration.maxNotificationAge = 240
    var custom = BridgeService(configuration: configuration, snapshotProvider: AgeTreeProvider(tree: tree), barkClient: client)
    #expect(try await custom.runOnce().map(\.title) == ["Fresh", "Old", "Unknown"])
    configuration.maxNotificationAge = 0
    var disabled = BridgeService(configuration: configuration, snapshotProvider: AgeTreeProvider(tree: tree), barkClient: client)
    #expect(try await disabled.runOnce().count == 3)
}

@Test func notificationAgeConfigurationPersistsAndRejectsInvalidInput() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConfigurationStore(configurationDirectoryProvider: { root })
    var stored = StoredConfiguration.defaults
    stored.deviceKey = "test"
    stored.maxNotificationAge = 300
    try store.save(stored)
    #expect(try store.load().maxNotificationAge == 300)
    stored.maxNotificationAge = 0
    try store.save(stored)
    #expect(try store.load().maxNotificationAge == 0)
    stored.maxNotificationAge = -1
    #expect(throws: BridgeError.self) { try store.save(stored) }
    stored.maxNotificationAge = .infinity
    #expect(throws: BridgeError.self) { try stored.resolved() }
    let baseArgs = ["bridge", "--device-key", "test", "--max-notification-age"]
    #expect(try AppConfiguration.parse(arguments: baseArgs + ["45"], environment: [:]).maxNotificationAge == 45)
    for invalid in ["-1", "nan", "inf", "text"] {
        #expect(throws: BridgeError.self) { try AppConfiguration.parse(arguments: baseArgs + [invalid], environment: [:]) }
    }
}

@Test func serviceRechecksAgeBeforeEachQueuedSend() async throws {
    let tree = AccessibilityNode(role: "AXApplication", children: [ageCard("First", time: "Now"), ageCard("Second", time: "Now")])
    var configuration = try AppConfiguration.parse(arguments: ["bridge", "--device-key", "test"], environment: [:])
    configuration.maxNotificationAge = 1
    let requests = AgeRequestRecorder()
    let logger = TestLogger()
    var service = BridgeService(
        configuration: configuration, snapshotProvider: AgeTreeProvider(tree: tree),
        barkClient: BarkClient(baseURL: configuration.barkBaseURL, deviceKey: "test", sender: { request in
            await requests.record()
            try await Task.sleep(for: .milliseconds(1200))
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }), logger: logger
    )
    #expect(try await service.runOnce().map(\.title) == ["First"])
    #expect(await requests.count == 1)
    let logs = await logger.messages()
    #expect(logs.contains { $0.contains("scan.not_sent reason=expired") })
}

private actor AgeRequestRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

private func ageCard(_ title: String, time: String?) -> AccessibilityNode {
    AccessibilityNode(role: "AXGroup", subrole: "AXNotificationCenterBanner", nodeDescription: "Example，\(title)", children: [
        AccessibilityNode(role: "AXStaticText", value: title),
        AccessibilityNode(role: "AXStaticText", value: "Body for \(title)"),
    ] + (time.map { [AccessibilityNode(role: "AXStaticText", value: $0, identifier: "notification-date")] } ?? []))
}

private struct AgeTreeProvider: NotificationSnapshotProviding {
    let tree: AccessibilityNode
    func snapshot() async throws -> AccessibilityNode { tree }
}
