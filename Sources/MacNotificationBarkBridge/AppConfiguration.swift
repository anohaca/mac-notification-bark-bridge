import Foundation

struct AppConfiguration: Equatable, Sendable {
    let deviceKey: String
    let barkBaseURL: URL
    let sourceFilter: String?
    let pollInterval: TimeInterval
    let dryRun: Bool
    let runOnce: Bool
    let dumpTree: Bool
    let fixturePath: String?
    let promptForAccessibility: Bool
    let dedupeWindow: TimeInterval
    let launchAtLogin: Bool

    static func parse(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppConfiguration {
        var deviceKey = environment["BARK_DEVICE_KEY"]
        var barkBaseURL = environment["BARK_BASE_URL"] ?? "https://api.day.app"
        var sourceFilter = environment["SOURCE_FILTER"]
        var pollInterval = environment["POLL_INTERVAL"] ?? "2"
        var dryRun = false
        var runOnce = false
        var dumpTree = false
        var fixturePath = environment["FIXTURE_PATH"]
        var promptForAccessibility = true
        var dedupeWindow = environment["DEDUPE_WINDOW"] ?? "300"

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--help", "-h":
                Self.printHelp()
                Foundation.exit(EXIT_SUCCESS)
            case "--device-key":
                index += 1
                deviceKey = try value(after: index, from: arguments, for: argument)
            case "--bark-base-url":
                index += 1
                barkBaseURL = try value(after: index, from: arguments, for: argument)
            case "--source-filter":
                index += 1
                sourceFilter = try value(after: index, from: arguments, for: argument)
            case "--poll-interval":
                index += 1
                pollInterval = try value(after: index, from: arguments, for: argument)
            case "--fixture":
                index += 1
                fixturePath = try value(after: index, from: arguments, for: argument)
            case "--dedupe-window":
                index += 1
                dedupeWindow = try value(after: index, from: arguments, for: argument)
            case "--dry-run":
                dryRun = true
            case "--once":
                runOnce = true
            case "--dump-tree":
                dumpTree = true
            case "--no-accessibility-prompt":
                promptForAccessibility = false
            default:
                throw BridgeError.invalidOption(argument)
            }

            index += 1
        }

        let trimmedDeviceKey = deviceKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedDeviceKey.isEmpty else {
            throw BridgeError.missingDeviceKey
        }

        guard let barkURL = URL(string: barkBaseURL) else {
            throw BridgeError.invalidBarkBaseURL(barkBaseURL)
        }

        guard let interval = TimeInterval(pollInterval), interval > 0 else {
            throw BridgeError.invalidPollInterval(pollInterval)
        }

        guard let dedupeSeconds = TimeInterval(dedupeWindow), dedupeSeconds > 0 else {
            throw BridgeError.invalidPollInterval(dedupeWindow)
        }

        if let configuredFixturePath = fixturePath {
            let expanded = NSString(string: configuredFixturePath).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw BridgeError.invalidFixturePath(expanded)
            }
            fixturePath = expanded
        }

        return AppConfiguration(
            deviceKey: trimmedDeviceKey,
            barkBaseURL: barkURL,
            sourceFilter: sourceFilter?.trimmingCharacters(in: .whitespacesAndNewlines),
            pollInterval: interval,
            dryRun: dryRun,
            runOnce: runOnce,
            dumpTree: dumpTree,
            fixturePath: fixturePath,
            promptForAccessibility: promptForAccessibility,
            dedupeWindow: dedupeSeconds,
            launchAtLogin: false
        )
    }

    private static func value(after index: Int, from arguments: [String], for option: String) throws -> String {
        guard arguments.indices.contains(index) else {
            throw BridgeError.invalidOption(option)
        }
        return arguments[index]
    }

    private static func printHelp() {
        let help = """
        mac-notification-bark-bridge

        通过辅助功能读取当前可见的通知中心界面，并把匹配到的通知转发到 Bark。

        必填：
          --device-key <key>           Bark 设备 Key，或设置 BARK_DEVICE_KEY

        可选：
          --menu-bar                   强制以菜单栏应用模式启动
          --bark-base-url <url>        Bark 服务地址，默认 https://api.day.app
          --source-filter <text>       只转发来源、标题或正文包含该文本的通知
          --poll-interval <seconds>    轮询间隔，默认 2 秒
          --dedupe-window <seconds>    去重时间窗口，默认 300 秒
          --dry-run                    只打印匹配结果，不调用 Bark
          --once                       扫描一次后退出
          --dump-tree                  以 JSON 打印抓到的辅助功能树
          --fixture <path>             使用保存好的树夹具，而不是读取实时通知中心
          --no-accessibility-prompt    不主动触发系统辅助功能授权提示
        """
        print(help)
    }
}
