import Foundation

struct NotificationParser: Sendable {
    private let containerRoles: Set<String> = [
        "AXApplication",
        "AXGroup",
        "AXList",
        "AXRow",
        "AXScrollArea",
        "AXWindow",
    ]
    private let notificationSubroles: Set<String> = [
        "AXNotificationCenterBanner",
        "AXNotificationCenterBannerStack",
    ]

    private let ignoredExactTexts: Set<String> = [
        "Notification Center",
        "通知中心",
        "通知",
        "Close",
        "关闭",
        "Options",
        "选项",
        "Clear",
        "Clear All",
        "清除",
        "清除全部",
        "Earlier Today",
        "今天稍早",
        "No Older Notifications",
        "没有更早的通知",
        "Now",
        "刚刚",
    ]

    func parse(from root: AccessibilityNode, sourceFilter: String?, now: Date = Date()) -> [ForwardedNotification] {
        let filterTerms = sourceFilter?
            .components(separatedBy: CharacterSet(charactersIn: ",，;；\n\r"))
            .map(\.fingerprint)
            .filter { !$0.isEmpty } ?? []
        let matches = collectCandidates(from: root, now: now, isInHistoryList: false)

        var indices: [String: Int] = [:]
        var exactUnique: [ForwardedNotification] = []
        for notification in matches {
            if let index = indices[notification.signature] {
                // Prefer real time metadata over an undated representation of the same node.
                if exactUnique[index].timestamp == nil && notification.timestamp != nil {
                    var resolved = notification
                    resolved.isNotificationCenterHistoryItem = exactUnique[index].isNotificationCenterHistoryItem
                        || notification.isNotificationCenterHistoryItem
                    exactUnique[index] = resolved
                } else if notification.isNotificationCenterHistoryItem {
                    exactUnique[index].isNotificationCenterHistoryItem = true
                }
            } else {
                indices[notification.signature] = exactUnique.count
                exactUnique.append(notification)
            }
        }
        let strongerTitleBodySignatures = Set(
            exactUnique
                .filter { !$0.usesFallbackSource }
                .map(\.titleBodySignature)
        )

        return exactUnique.filter { notification in
            guard notification.usesFallbackSource else {
                return true
            }

            return !strongerTitleBodySignatures.contains(notification.titleBodySignature)
        }.filter { matchesFilter($0, terms: filterTerms) }
    }

    private func collectCandidates(
        from node: AccessibilityNode,
        now: Date,
        isInHistoryList: Bool
    ) -> [ForwardedNotification] {
        let isInHistoryList = isInHistoryList || node.identifier?.fingerprint == "axnotificationlistitems"
        if let subrole = node.subrole, notificationSubroles.contains(subrole) {
            let nestedCards = node.children.flatMap { notificationContainers(in: $0) }
            if !nestedCards.isEmpty {
                return nestedCards.flatMap {
                    collectCandidates(from: $0, now: now, isInHistoryList: isInHistoryList)
                }
            }
            // Parse a card as one unit, so nested content groups cannot lose its metadata.
            return candidate(from: node, now: now, isInHistoryList: isInHistoryList).map { [$0] } ?? []
        }
        let childMatches = node.children.flatMap {
            collectCandidates(from: $0, now: now, isInHistoryList: isInHistoryList)
        }
        if !childMatches.isEmpty { return childMatches }
        return candidate(from: node, now: now, isInHistoryList: isInHistoryList).map { [$0] } ?? []
    }

    private func notificationContainers(in node: AccessibilityNode) -> [AccessibilityNode] {
        if let subrole = node.subrole, notificationSubroles.contains(subrole) { return [node] }
        return node.children.flatMap { notificationContainers(in: $0) }
    }

    private func isTimeNode(_ node: AccessibilityNode) -> Bool {
        let roles: Set<String> = ["AXDateTimeArea", "AXDateField", "AXTimeField"]
        if roles.contains(node.role ?? "") || roles.contains(node.subrole ?? "") { return true }
        guard let identifier = node.identifier?.lowercased() else { return false }
        return identifier.range(
            of: #"(?:^|[._-])(?:date|time|timestamp|datelabel|timelabel|notificationdate|notificationtime)$"#,
            options: .regularExpression
        ) != nil
    }

    private func timestamp(in node: AccessibilityNode, now: Date) -> Date? {
        if ["title", "body"].contains(node.identifier?.lowercased() ?? "") { return nil }
        if isTimeNode(node) {
            return timeValue(in: node, now: now)
        }
        return node.children.compactMap { child in
            if isAnonymousCardTime(child, parent: node, now: now) { return timeValue(in: child, now: now) }
            return timestamp(in: child, now: now)
        }.min()
    }

    private func timeValue(in node: AccessibilityNode, now: Date) -> Date? {
        let parser = NotificationTimeParser()
        return [node.value, node.title, node.nodeDescription].compactMap { $0 }
            .compactMap { parser.date(from: $0, now: now) }.min()
    }

    private func isAnonymousCardTime(_ node: AccessibilityNode, parent: AccessibilityNode, now: Date) -> Bool {
        guard notificationSubroles.contains(parent.subrole ?? ""),
              node.role == "AXStaticText", node.children.isEmpty,
              node.identifier?.isEmpty ?? true else { return false }
        // macOS places an unnamed time label beside explicitly named title/body fields.
        let contentIDs = Set(parent.children.compactMap { $0.identifier?.lowercased() })
        guard contentIDs.contains("title"), contentIDs.contains("body") else { return false }
        return timeValue(in: node, now: now) != nil
    }

    private func candidate(
        from node: AccessibilityNode,
        now: Date,
        isInHistoryList: Bool
    ) -> ForwardedNotification? {
        guard let role = node.role, containerRoles.contains(role) else {
            return nil
        }

        let rawTexts = leafTexts(in: node, now: now)
            .map(cleanText)
            .filter { !$0.isEmpty }
        let timestamp = timestamp(in: node, now: now)
        let texts = rawTexts
            .filter { !ignoredExactTexts.contains($0) }
            .stableUniqued()

        if let subrole = node.subrole, notificationSubroles.contains(subrole) {
            return notificationCenterCandidate(
                from: node,
                texts: texts,
                timestamp: timestamp,
                isInHistoryList: isInHistoryList
            )
        }

        guard role == "AXGroup" || role == "AXRow" else { return nil }

        guard texts.count >= 2, texts.count <= 6 else {
            return nil
        }

        let joined = texts.joined(separator: " ")
        guard joined.count <= 400 else {
            return nil
        }

        let source = texts[0]
        let title: String
        let body: String

        if texts.count == 2 {
            title = source
            body = texts[1]
        } else {
            title = texts[1]
            body = texts.dropFirst(2).joined(separator: "\n")
        }

        guard !body.isEmpty else {
            return nil
        }

        return ForwardedNotification(
            source: source,
            title: title,
            body: body,
            identifier: node.identifier,
            timestamp: timestamp,
            isNotificationCenterHistoryItem: isInHistoryList
        )
    }

    private func notificationCenterCandidate(
        from node: AccessibilityNode,
        texts: [String],
        timestamp: Date?,
        isInHistoryList: Bool
    ) -> ForwardedNotification? {
        guard texts.count >= 2 else {
            return nil
        }

        let title = texts[0]
        let body = texts.dropFirst().joined(separator: "\n")
        guard !body.isEmpty else {
            return nil
        }

        let source = notificationSource(from: node, title: title) ?? title

        return ForwardedNotification(
            source: source,
            title: title,
            body: body,
            identifier: node.identifier,
            timestamp: timestamp,
            isNotificationCenterHistoryItem: isInHistoryList
        )
    }

    private func notificationSource(from node: AccessibilityNode, title: String) -> String? {
        guard let description = node.nodeDescription.map(cleanText), !description.isEmpty else {
            return nil
        }

        let separators = ["，", ","]
        guard let separator = separators.first(where: { description.contains($0) }) else {
            return nil
        }

        let prefix = description
            .components(separatedBy: separator)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prefix.isEmpty else {
            return nil
        }

        if prefix.hasSuffix(title) {
            let stripped = String(prefix.dropLast(title.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }

        return prefix
    }

    private func leafTexts(in node: AccessibilityNode, now: Date) -> [String] {
        if isTimeNode(node) { return [] }
        if node.children.isEmpty {
            return [node.title, node.value, node.nodeDescription].compactMap { $0 }
        }

        return node.children.flatMap { child in
            isAnonymousCardTime(child, parent: node, now: now) ? [] : leafTexts(in: child, now: now)
        }
    }

    private func cleanText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func matchesFilter(_ notification: ForwardedNotification, terms: [String]) -> Bool {
        guard !terms.isEmpty else {
            return true
        }

        let haystack = [
            notification.source,
            notification.title,
            notification.body,
        ].joined(separator: "\n").fingerprint

        return terms.contains { haystack.contains($0) }
    }

}
