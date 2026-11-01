import Foundation

struct BridgeService: Sendable {
    private let timestampResolutionRetryCount = 2
    private let timestampResolutionRetryDelayNanoseconds: UInt64 = 250_000_000

    private struct ScanSummary: Equatable, Sendable {
        let panelVisible: Bool
        let topLevelChildren: Int
        let totalNodes: Int
        let matches: Int
        let eligible: Int
        let fresh: Int
    }

    let configuration: AppConfiguration
    let snapshotProvider: any NotificationSnapshotProviding
    let parser: NotificationParser
    let barkClient: BarkClient
    let logger: any BridgeLogging
    var deduper: Deduper
    private var lastScanSummary: ScanSummary?
    private let passwordPromptProvider: (any PasswordPromptProviding)?
    var passwordPromptTracker = PasswordPromptTracker()
    private var lastPromptScanError: String?
    private var lastPromptScanSummary: String?
    private var lastAgeFilterSummary: String?

    init(
        configuration: AppConfiguration,
        snapshotProvider: any NotificationSnapshotProviding,
        parser: NotificationParser = NotificationParser(),
        barkClient: BarkClient,
        logger: any BridgeLogging = NoopBridgeLogger(),
        passwordPromptProvider: (any PasswordPromptProviding)? = nil
    ) {
        self.configuration = configuration
        self.snapshotProvider = snapshotProvider
        self.parser = parser
        self.barkClient = barkClient
        self.logger = logger
        self.deduper = Deduper(window: configuration.dedupeWindow)
        self.lastScanSummary = nil
        self.passwordPromptProvider = passwordPromptProvider
    }

    mutating func run(log: (String) -> Void = { print($0) }) async throws {
        repeat {
            let notifications = try await runOnce()

            for notification in notifications {
                log(logMessage(for: notification))
            }

            if configuration.runOnce {
                break
            }

            let nanoseconds = UInt64(configuration.pollInterval * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        } while true
    }

    mutating func runOnce() async throws -> [ForwardedNotification] {
        let promptNotifications = try await forwardPasswordPrompts()
        var tree: AccessibilityNode
        do {
            tree = try await snapshotProvider.snapshot()
        } catch {
            await logger.log(.error, "scan.snapshot_failed error=\(describe(error))")
            throw error
        }

        await logger.storeSnapshot(tree)

        if configuration.dumpTree {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(tree)
            if let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        }

        var scanTime = Date()
        var notifications = parser.parse(from: tree, sourceFilter: configuration.sourceFilter, now: scanTime)
        if configuration.maxNotificationAge > 0, tree.notificationPanelVisible {
            var totalResolvedCount = 0
            var retryAttempts = 0
            for attempt in 1...timestampResolutionRetryCount {
                let unresolved = notifications.filter { $0.timestamp == nil }
                guard !unresolved.isEmpty else { break }

                retryAttempts = attempt
                try await Task.sleep(nanoseconds: timestampResolutionRetryDelayNanoseconds)
                let retryTree: AccessibilityNode
                do {
                    retryTree = try await snapshotProvider.snapshot()
                } catch {
                    await logger.log(.warning, "scan.timestamp_retry_failed attempt=\(attempt) error=\(describe(error))")
                    break
                }
                await logger.storeSnapshot(retryTree)
                tree = retryTree
                scanTime = Date()
                let retryNotifications = parser.parse(
                    from: retryTree,
                    sourceFilter: configuration.sourceFilter,
                    now: scanTime
                )
                let knownByHash = Dictionary(
                    grouping: retryNotifications.filter { $0.timestamp != nil },
                    by: \.exactDedupeHash
                )
                var resolvedCount = 0
                notifications = notifications.map { notification in
                    guard notification.timestamp == nil,
                          let known = knownByHash[notification.exactDedupeHash]?.first else {
                        return notification
                    }
                    resolvedCount += 1
                    return known
                }
                totalResolvedCount += resolvedCount
                if resolvedCount == unresolved.count { break }
            }
            if totalResolvedCount > 0 {
                await logger.log(.info, "scan.timestamp_resolved attempts=\(retryAttempts) count=\(totalResolvedCount)")
            }
        }

        let agePolicy = NotificationAgePolicy(maxAge: configuration.maxNotificationAge)
        var rejections: [String: Int] = [:]
        let eligible = notifications.filter { notification in
            guard let reason = agePolicy.rejectionReason(
                timestamp: notification.timestamp,
                now: scanTime,
                rejectUnknownTimestamp: notification.isNotificationCenterHistoryItem
            ) else { return true }
            rejections[reason, default: 0] += 1
            return false
        }
        let unknownCount = notifications.filter { $0.timestamp == nil }.count
        let ageSummary = "scan.age_filter allowed=\(eligible.count) expired=\(rejections["expired", default: 0]) timeUnknown=\(unknownCount) unknownHistoryDropped=\(rejections["time_unknown", default: 0]) future=\(rejections["time_in_future", default: 0]) invalidTime=\(rejections["time_invalid", default: 0]) maxAgeSeconds=\(configuration.maxNotificationAge) unknownPolicy=history_drop_live_forward"
        if ageSummary != lastAgeFilterSummary {
            await logger.log(.info, ageSummary)
            lastAgeFilterSummary = ageSummary
        }
        let panelVisible = tree.notificationPanelVisible
        let fresh = deduper.filterNew(eligible)
        let summary = ScanSummary(
            panelVisible: panelVisible,
            topLevelChildren: tree.children.count,
            totalNodes: tree.totalNodeCount,
            matches: notifications.count,
            eligible: eligible.count,
            fresh: fresh.count
        )
        if summary != lastScanSummary {
            await logger.log(
                .info,
                "scan.snapshot rootRole=\(tree.role ?? "-") rootTitle=\(tree.title ?? "-") topLevelChildren=\(tree.children.count) totalNodes=\(tree.totalNodeCount)"
            )
            await logger.log(
                .info,
                "scan.parsed matches=\(notifications.count) eligible=\(eligible.count) fresh=\(fresh.count) deduped=\(eligible.count - fresh.count)"
            )
            if summary.panelVisible && notifications.isEmpty {
                await logger.log(.warning, "scan.zero_matches latestSnapshotUpdated=true")
            }
            lastScanSummary = summary
        }

        var delivered: [ForwardedNotification] = []
        for notification in fresh {
            if let reason = agePolicy.rejectionReason(
                timestamp: notification.timestamp,
                now: Date(),
                rejectUnknownTimestamp: notification.isNotificationCenterHistoryItem
            ) {
                await logger.log(.info, "scan.not_sent reason=\(reason) hash=\(notification.exactDedupeHash)")
                continue
            }
            await logger.log(.info, notificationLogMessage(for: notification))
            if notification.timestamp == nil {
                await logger.log(.info, "scan.time_unknown action=forward hash=\(notification.exactDedupeHash)")
            }
            guard !configuration.dryRun else {
                delivered.append(notification)
                continue
            }
            do {
                try await barkClient.send(notification)
                delivered.append(notification)
                await logger.log(.info, "scan.forwarded title=\(notification.barkTitle)")
            } catch {
                await logger.log(.error, "scan.forward_failed title=\(notification.barkTitle) error=\(describe(error))")
                throw error
            }
        }

        return promptNotifications + delivered
    }

    private mutating func forwardPasswordPrompts() async throws -> [ForwardedNotification] {
        guard configuration.monitorPasswordPrompts, let passwordPromptProvider else { return [] }
        let snapshot: PasswordPromptSnapshot
        do {
            snapshot = try await passwordPromptProvider.snapshot()
            if lastPromptScanError != nil { await logger.log(.info, "prompt.scan_recovered") }
            lastPromptScanError = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let message = describe(error)
            if message != lastPromptScanError {
                await logger.log(.error, "prompt.scan_failed error=\(message)")
                lastPromptScanError = message
            }
            return []
        }
        let pending = passwordPromptTracker.pending(in: snapshot)
        let summary = "prompt.scan matches=\(snapshot.prompts.count) pending=\(pending.count)"
        if summary != lastPromptScanSummary {
            await logger.log(.info, "\(summary) uncertainProcesses=\(snapshot.uncertainProcessIDs.count)")
            lastPromptScanSummary = summary
        }
        var forwarded: [ForwardedNotification] = []
        for prompt in pending {
            try Task.checkCancellation()
            do {
                if !configuration.dryRun { try await barkClient.send(prompt.notification) }
                passwordPromptTracker.markSent(prompt)
                forwarded.append(prompt.notification)
                await logger.log(.info, "prompt.\(configuration.dryRun ? "detected" : "forwarded") app=\(prompt.applicationName) pid=\(prompt.processID)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await logger.log(.error, "prompt.forward_failed app=\(prompt.applicationName) error=\(describe(error))")
            }
        }
        return forwarded
    }

    func notificationLogMessage(for notification: ForwardedNotification) -> String {
        "scan.notification source=\(notification.source) title=\(notification.title) bodyLength=\(notification.body.count) bodyRedacted=true"
    }

    func logMessage(for notification: ForwardedNotification) -> String {
        if configuration.dryRun {
            return "Would send Bark: [\(notification.barkTitle)] \(notification.body)"
        }
        return "Forwarded: [\(notification.barkTitle)] \(notification.body)"
    }
}

struct Deduper: Sendable {
    let window: TimeInterval
    private var seenHashes: [String: Date] = [:]

    init(window: TimeInterval) {
        self.window = window
    }

    mutating func filterNew(_ notifications: [ForwardedNotification], now: Date = Date()) -> [ForwardedNotification] {
        seenHashes = seenHashes.filter { now.timeIntervalSince($0.value) < window }

        return notifications.filter { notification in
            let hash = notification.exactDedupeHash
            if seenHashes[hash] != nil {
                return false
            }
            seenHashes[hash] = now
            return true
        }
    }
}

func makeBridgeService(
    configuration: AppConfiguration,
    logger: any BridgeLogging = FileBridgeLogger()
) -> BridgeService {
    let snapshotProvider: any NotificationSnapshotProviding
    if let fixturePath = configuration.fixturePath {
        snapshotProvider = FixtureSnapshotProvider(path: fixturePath)
    } else {
        snapshotProvider = AccessibilityNotificationSnapshotProvider(
            promptForAccessibility: configuration.promptForAccessibility,
            logger: logger
        )
    }

    let barkClient = BarkClient(
        baseURL: configuration.barkBaseURL,
        deviceKey: configuration.deviceKey
    )

    return BridgeService(
        configuration: configuration,
        snapshotProvider: snapshotProvider,
        barkClient: barkClient,
        logger: logger,
        passwordPromptProvider: configuration.fixturePath == nil ? AccessibilityPasswordPromptProvider() : nil
    )
}
