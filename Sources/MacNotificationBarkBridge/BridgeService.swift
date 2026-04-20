import Foundation

struct BridgeService: Sendable {
    private struct ScanSummary: Equatable, Sendable {
        let panelVisible: Bool
        let topLevelChildren: Int
        let totalNodes: Int
        let matches: Int
        let fresh: Int
    }

    let configuration: AppConfiguration
    let snapshotProvider: any NotificationSnapshotProviding
    let parser: NotificationParser
    let barkClient: BarkClient
    let logger: any BridgeLogging
    var deduper: Deduper
    private var lastScanSummary: ScanSummary?

    init(
        configuration: AppConfiguration,
        snapshotProvider: any NotificationSnapshotProviding,
        parser: NotificationParser = NotificationParser(),
        barkClient: BarkClient,
        logger: any BridgeLogging = NoopBridgeLogger()
    ) {
        self.configuration = configuration
        self.snapshotProvider = snapshotProvider
        self.parser = parser
        self.barkClient = barkClient
        self.logger = logger
        self.deduper = Deduper(window: configuration.dedupeWindow)
        self.lastScanSummary = nil
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
        let tree: AccessibilityNode
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

        let notifications = parser.parse(from: tree, sourceFilter: configuration.sourceFilter)
        let fresh = deduper.filterNew(notifications)
        let summary = ScanSummary(
            panelVisible: tree.notificationPanelVisible,
            topLevelChildren: tree.children.count,
            totalNodes: tree.totalNodeCount,
            matches: notifications.count,
            fresh: fresh.count
        )
        if summary != lastScanSummary {
            await logger.log(
                .info,
                "scan.snapshot rootRole=\(tree.role ?? "-") rootTitle=\(tree.title ?? "-") topLevelChildren=\(tree.children.count) totalNodes=\(tree.totalNodeCount)"
            )
            await logger.log(
                .info,
                "scan.parsed matches=\(notifications.count) fresh=\(fresh.count) deduped=\(notifications.count - fresh.count)"
            )
            if summary.panelVisible && notifications.isEmpty {
                await logger.log(.warning, "scan.zero_matches latestSnapshotUpdated=true")
            }
            lastScanSummary = summary
        }

        for notification in fresh {
            await logger.log(.info, notificationLogMessage(for: notification))
            guard !configuration.dryRun else {
                continue
            }
            do {
                try await barkClient.send(notification)
                await logger.log(.info, "scan.forwarded title=\(notification.barkTitle)")
            } catch {
                await logger.log(.error, "scan.forward_failed title=\(notification.barkTitle) error=\(describe(error))")
                throw error
            }
        }

        return fresh
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
    private var seen: [String: Date] = [:]

    init(window: TimeInterval) {
        self.window = window
    }

    mutating func filterNew(_ notifications: [ForwardedNotification], now: Date = Date()) -> [ForwardedNotification] {
        seen = seen.filter { now.timeIntervalSince($0.value) < window }

        return notifications.filter { notification in
            if seen[notification.signature] != nil {
                return false
            }
            seen[notification.signature] = now
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
        logger: logger
    )
}
