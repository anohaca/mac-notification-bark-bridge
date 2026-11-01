import Foundation
import Testing
@testable import MacNotificationBarkBridge

@Test func parserExtractsNotificationFromFixture() throws {
    let fixtureURL = try #require(Bundle.module.url(
        forResource: "sample-notification-tree",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    let data = try Data(contentsOf: fixtureURL)
    let tree = try JSONDecoder().decode(AccessibilityNode.self, from: data)

    let parser = NotificationParser()
    let notifications = parser.parse(from: tree, sourceFilter: "messages")

    #expect(notifications.count == 1)
    #expect(notifications.first?.source == "Messages")
    #expect(notifications.first?.title == "Alice")
    #expect(notifications.first?.body == "Meet at 8 PM\nBring the tickets.")
}

@Test func parserTreatsSeparatedSourceFilterTermsAsAlternatives() throws {
    func card(source: String, title: String) -> AccessibilityNode {
        AccessibilityNode(
            role: "AXGroup",
            subrole: "AXNotificationCenterBanner",
            nodeDescription: "\(source)，\(title)",
            children: [
                AccessibilityNode(role: "AXStaticText", value: title),
                AccessibilityNode(role: "AXStaticText", value: "Body for \(title)"),
            ]
        )
    }
    let tree = AccessibilityNode(role: "AXApplication", children: [
        AccessibilityNode(role: "AXWindow", children: [
            card(source: "Slack", title: "Build complete"),
            card(source: "Messages", title: "New message"),
        ]),
    ])
    let parser = NotificationParser()

    #expect(parser.parse(from: tree, sourceFilter: "ChatGPT, Slack").map(\.source) == ["Slack"])
    #expect(parser.parse(from: tree, sourceFilter: "ChatGPT，Slack；Messages").map(\.source) == ["Slack", "Messages"])
    #expect(parser.parse(from: tree, sourceFilter: " , ; ChatGPT,  ").isEmpty)
    #expect(parser.parse(from: tree, sourceFilter: nil).count == 2)
}

@Test func parserExtractsLongNotificationCenterStackUsingDescriptionAsSource() throws {
    let longBody = String(repeating: "Long codex reply. ", count: 40)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let tree = AccessibilityNode(
        role: "AXApplication",
        children: [
            AccessibilityNode(
                role: "AXWindow",
                children: [
                    AccessibilityNode(
                        role: "AXGroup",
                        subrole: "AXNotificationCenterBannerStack",
                        nodeDescription: "Codex，编写监听应用通知的Swift后台程序, \(longBody)，已叠放",
                        identifier: "codex-stack-1",
                        children: [
                            AccessibilityNode(role: "AXStaticText", value: "编写监听应用通知的Swift后台程序"),
                            AccessibilityNode(role: "AXStaticText", value: "\(longBody) "),
                            AccessibilityNode(role: "AXDateTimeArea", value: "15分钟前"),
                        ]
                    )
                ]
            )
        ]
    )

    let parser = NotificationParser()
    let notifications = parser.parse(from: tree, sourceFilter: nil)

    #expect(notifications.count == 1)
    #expect(notifications.first?.source == "Codex")
    #expect(notifications.first?.title == "编写监听应用通知的Swift后台程序")
    #expect(notifications.first?.body == longBody)
}

@Test func parserPrefersResolvedSourceOverFallbackDuplicate() throws {
    let tree = AccessibilityNode(
        role: "AXApplication",
        children: [
            AccessibilityNode(
                role: "AXWindow",
                children: [
                    AccessibilityNode(
                        role: "AXGroup",
                        subrole: "AXNotificationCenterBanner",
                        nodeDescription: "Keka 提取完成, 提取“archive.zip”完成",
                        identifier: "keka-banner-1",
                        children: [
                            AccessibilityNode(role: "AXStaticText", value: "提取完成"),
                            AccessibilityNode(role: "AXStaticText", value: "提取“archive.zip”完成"),
                            AccessibilityNode(
                                role: "AXGroup",
                                children: [
                                    AccessibilityNode(role: "AXStaticText", value: "提取完成"),
                                    AccessibilityNode(role: "AXStaticText", value: "提取“archive.zip”完成"),
                                ]
                            ),
                        ]
                    )
                ]
            )
        ]
    )

    let parser = NotificationParser()
    let notifications = parser.parse(from: tree, sourceFilter: nil)

    #expect(notifications.count == 1)
    #expect(notifications.first?.source == "Keka")
    #expect(notifications.first?.title == "提取完成")
    #expect(notifications.first?.body == "提取“archive.zip”完成")
}
