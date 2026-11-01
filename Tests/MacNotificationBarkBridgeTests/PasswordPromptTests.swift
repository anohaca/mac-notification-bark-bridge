import Foundation
import Testing
@testable import MacNotificationBarkBridge

@Test func passwordPromptRejectsAppOwnedPanelsAndRequiresSystemOrAgentContext() {
    let secureField = AccessibilityNode(
        role: "AXTextField", subrole: "AXSecureTextField", value: "must-never-leave-this-test"
    )
    let ordinaryWindow = AccessibilityNode(role: "AXWindow", children: [secureField])
    let appDialog = AccessibilityNode(role: "AXWindow", subrole: "AXDialog", children: [secureField])
    let sheet = AccessibilityNode(role: "AXSheet", children: [secureField])
    let systemDialog = AccessibilityNode(role: "AXWindow", subrole: "AXSystemDialog", children: [secureField])
    let classifier = PasswordPromptClassifier()

    #expect(!classifier.matches(ordinaryWindow))
    #expect(!classifier.matches(appDialog))
    #expect(!classifier.matches(sheet))
    #expect(!classifier.matches(AccessibilityNode(role: "AXWindow", subrole: "AXDialog")))
    #expect(classifier.matches(systemDialog))
    #expect(!classifier.matches(AccessibilityNode(role: "AXWindow"), isAuthorizationAgent: true))
    #expect(classifier.matches(ordinaryWindow, isAuthorizationAgent: true))

    let prompt = PasswordPrompt(id: "1:10", processID: 1, applicationName: "Example")
    #expect(prompt.notification.source == "Example")
    #expect(prompt.notification.body.contains("must-never-leave-this-test") == false)
}

@Test func passwordPromptRemindsOnceUntilClosedAndRetriesFailedSend() {
    var tracker = PasswordPromptTracker()
    let first = PasswordPrompt(id: "1:10", processID: 1, applicationName: "Example")
    let second = PasswordPrompt(id: "1:11", processID: 1, applicationName: "Example")
    let visible = PasswordPromptSnapshot(prompts: [first], uncertainProcessIDs: [])

    #expect(tracker.pending(in: visible) == [first])
    // No acknowledgement represents a failed Bark request: retry next time.
    #expect(tracker.pending(in: visible) == [first])
    tracker.markSent(first)
    #expect(tracker.pending(in: visible).isEmpty)
    #expect(tracker.pending(in: .init(prompts: [], uncertainProcessIDs: [1])).isEmpty)
    #expect(tracker.pending(in: visible).isEmpty)
    #expect(tracker.pending(in: .init(prompts: [first, second], uncertainProcessIDs: [])) == [second])
    tracker.markSent(second)
    #expect(tracker.pending(in: .init(prompts: [], uncertainProcessIDs: [])).isEmpty)
    #expect(tracker.pending(in: visible) == [first])
}

@Test func bridgeSendsPromptsDespiteSourceFilterAndRetriesThenRearmsAfterClose() async throws {
    let prompt = PasswordPrompt(id: "5:1", processID: 5, applicationName: "Installer")
    let visible = PasswordPromptSnapshot(prompts: [prompt], uncertainProcessIDs: [])
    let provider = PromptSequenceProvider(snapshots: [visible, visible, visible, .init(prompts: [], uncertainProcessIDs: []), visible])
    let sender = PromptTestSender()
    let configuration = try AppConfiguration.parse(
        arguments: ["bridge", "--device-key", "test", "--password-prompts", "--source-filter", "Mail"],
        environment: [:]
    )
    let logger = TestLogger()
    var service = BridgeService(
        configuration: configuration,
        snapshotProvider: EmptyNotificationProvider(),
        barkClient: BarkClient(baseURL: configuration.barkBaseURL, deviceKey: "test", sender: { request in
            try await sender.send(request)
        }),
        logger: logger,
        passwordPromptProvider: provider
    )
    #expect(try await service.runOnce().isEmpty)
    #expect(try await service.runOnce() == [prompt.notification])
    #expect(try await service.runOnce().isEmpty)
    #expect(try await service.runOnce().isEmpty)
    #expect(try await service.runOnce() == [prompt.notification])
    #expect(await sender.attempts == 3)
    let logs = await logger.messages()
    #expect(logs.contains { $0.contains("prompt.forward_failed") })
    #expect(logs.filter { $0.contains("prompt.forwarded") }.count == 2)
}

@Test func disabledPasswordPromptMonitoringDoesNotScanOtherApplications() async throws {
    let configuration = try AppConfiguration.parse(arguments: ["bridge", "--device-key", "test"], environment: [:])
    let provider = PromptSequenceProvider(snapshots: [])
    var service = BridgeService(
        configuration: configuration,
        snapshotProvider: EmptyNotificationProvider(),
        barkClient: BarkClient(baseURL: configuration.barkBaseURL, deviceKey: "test"),
        passwordPromptProvider: provider
    )
    #expect(try await service.runOnce().isEmpty)
    #expect(await provider.calls == 0)
}

@Test func promptAcknowledgementSurvivesNotificationScanFailure() async throws {
    let prompt = PasswordPrompt(id: "6:1", processID: 6, applicationName: "Installer")
    let visible = PasswordPromptSnapshot(prompts: [prompt], uncertainProcessIDs: [])
    let configuration = try AppConfiguration.parse(
        arguments: ["bridge", "--device-key", "test", "--password-prompts", "--dry-run"], environment: [:]
    )
    let logger = TestLogger()
    var service = BridgeService(
        configuration: configuration,
        snapshotProvider: FailingOnceNotificationProvider(),
        barkClient: BarkClient(baseURL: configuration.barkBaseURL, deviceKey: "test", sender: { _ in
            Issue.record("Prompt dry-run must not send a network request")
            throw URLError(.badServerResponse)
        }),
        logger: logger,
        passwordPromptProvider: PromptSequenceProvider(snapshots: [visible, visible])
    )
    // Match the menu-bar caller's copy/run/retain acknowledgement flow on error.
    var cycle = service
    await #expect(throws: BridgeError.self) { _ = try await cycle.runOnce() }
    service.passwordPromptTracker = cycle.passwordPromptTracker
    #expect(try await service.runOnce().isEmpty)
    let logs = await logger.messages()
    #expect(logs.filter { $0.contains("prompt.detected") }.count == 1)
}

private actor FailingOnceNotificationProvider: NotificationSnapshotProviding {
    private var failed = false

    func snapshot() async throws -> AccessibilityNode {
        if !failed {
            failed = true
            throw BridgeError.notificationCenterNotRunning
        }
        return AccessibilityNode(role: "AXApplication")
    }
}

private struct EmptyNotificationProvider: NotificationSnapshotProviding {
    func snapshot() async throws -> AccessibilityNode { AccessibilityNode(role: "AXApplication") }
}

private actor PromptSequenceProvider: PasswordPromptProviding {
    let snapshots: [PasswordPromptSnapshot]
    private(set) var calls = 0

    init(snapshots: [PasswordPromptSnapshot]) { self.snapshots = snapshots }

    func snapshot() async throws -> PasswordPromptSnapshot {
        defer { calls += 1 }
        return snapshots[min(calls, snapshots.count - 1)]
    }
}

private actor PromptTestSender {
    private(set) var attempts = 0

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        attempts += 1
        if attempts == 1 { throw URLError(.notConnectedToInternet) }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
