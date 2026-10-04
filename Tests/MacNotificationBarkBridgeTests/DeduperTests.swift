import Foundation
import Testing
@testable import MacNotificationBarkBridge

@Test func deduperSkipsRecentDuplicates() {
    var deduper = Deduper(window: 300)
    let notification = ForwardedNotification(
        source: "Messages",
        title: "Alice",
        body: "Meet at 8",
        identifier: "n1"
    )

    let first = deduper.filterNew([notification], now: Date(timeIntervalSince1970: 100))
    let second = deduper.filterNew([notification], now: Date(timeIntervalSince1970: 200))
    let changedNotification = ForwardedNotification(
        source: "Messages",
        title: "Alice",
        body: "Meet at 9",
        identifier: "n2"
    )
    let third = deduper.filterNew([changedNotification], now: Date(timeIntervalSince1970: 450))

    #expect(first == [notification])
    #expect(second.isEmpty)
    #expect(third == [changedNotification])
}

@Test func deduperIgnoresAccessibilityIdentifierChanges() {
    var deduper = Deduper(window: 300)
    let first = ForwardedNotification(
        source: "Messages",
        title: "Alice",
        body: "Meet at 8",
        identifier: "banner-1"
    )
    let sameNotificationInNotificationCenter = ForwardedNotification(
        source: "Messages",
        title: "Alice",
        body: "Meet at 8",
        identifier: "card-1"
    )

    #expect(deduper.filterNew([first], now: Date(timeIntervalSince1970: 100)) == [first])
    #expect(deduper.filterNew([sameNotificationInNotificationCenter], now: Date(timeIntervalSince1970: 101)).isEmpty)
}

@Test func deduperTreatsBodyChangesAsNewMessages() {
    var deduper = Deduper(window: 300)
    let first = ForwardedNotification(
        source: "ChatGPT",
        title: "项目进度",
        body: "第一段正文",
        identifier: "card-1"
    )
    let rerendered = ForwardedNotification(
        source: "ChatGPT",
        title: "项目进度",
        body: "第一段正文，重新渲染后增加了内容",
        identifier: "card-2"
    )

    #expect(deduper.filterNew([first], now: Date(timeIntervalSince1970: 100)) == [first])
    #expect(deduper.filterNew([rerendered], now: Date(timeIntervalSince1970: 101)) == [rerendered])
}

@Test func deduperExpiresExactHashAfterWindow() {
    var deduper = Deduper(window: 300)
    let first = ForwardedNotification(
        source: "Messages",
        title: "Alice",
        body: "Meet at 8",
        identifier: "banner-1"
    )
    let sameContentLater = ForwardedNotification(
        source: "Messages",
        title: "Alice",
        body: "Meet at 8",
        identifier: "card-1"
    )

    #expect(deduper.filterNew([first], now: Date(timeIntervalSince1970: 100)) == [first])
    #expect(deduper.filterNew([sameContentLater], now: Date(timeIntervalSince1970: 200)).isEmpty)
    #expect(deduper.filterNew([sameContentLater], now: Date(timeIntervalSince1970: 450)) == [sameContentLater])
}

@Test func notificationDedupeKeysAreHashes() {
    let notification = ForwardedNotification(
        source: "Messages",
        title: "Alice",
        body: "Meet at 8",
        identifier: "card-1"
    )

    #expect(notification.exactDedupeHash.count == 64)
    #expect(notification.exactDedupeHash.contains("Meet at 8") == false)
}
