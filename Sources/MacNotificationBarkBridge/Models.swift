import Foundation

struct AccessibilityNode: Codable, Equatable, Sendable {
    var role: String?
    var subrole: String?
    var title: String?
    var value: String?
    var nodeDescription: String?
    var identifier: String?
    var children: [AccessibilityNode]

    init(
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        nodeDescription: String? = nil,
        identifier: String? = nil,
        children: [AccessibilityNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.nodeDescription = nodeDescription
        self.identifier = identifier
        self.children = children
    }

    enum CodingKeys: String, CodingKey {
        case role
        case subrole
        case title
        case value
        case nodeDescription = "description"
        case identifier
        case children
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        subrole = try container.decodeIfPresent(String.self, forKey: .subrole)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        nodeDescription = try container.decodeIfPresent(String.self, forKey: .nodeDescription)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        children = try container.decodeIfPresent([AccessibilityNode].self, forKey: .children) ?? []
    }
}

struct ForwardedNotification: Equatable, Hashable, Sendable {
    let source: String
    let title: String
    let body: String
    let identifier: String?

    var signature: String {
        [
            identifier ?? "",
            source.fingerprint,
            title.fingerprint,
            body.fingerprint,
        ].joined(separator: "|")
    }

    var contentSignature: String {
        [
            source.fingerprint,
            title.fingerprint,
            body.fingerprint,
        ].joined(separator: "|")
    }

    var titleBodySignature: String {
        [
            title.fingerprint,
            body.fingerprint,
        ].joined(separator: "|")
    }

    // Accessibility identifiers can change when Notification Center switches views.
    var dedupeSignature: String {
        titleBodySignature
    }

    var usesFallbackSource: Bool {
        source.fingerprint == title.fingerprint
    }

    var barkTitle: String {
        if title.fingerprint == source.fingerprint {
            return source
        }
        return "\(source) | \(title)"
    }
}

enum BridgeError: Error, CustomStringConvertible, Sendable {
    case missingDeviceKey
    case invalidBarkBaseURL(String)
    case invalidPollInterval(String)
    case invalidFieldValue(field: String, reason: String)
    case invalidOption(String)
    case invalidFixturePath(String)
    case invalidConfigurationFile(path: String, reason: String)
    case missingBundledTemplate
    case accessibilityPermissionDenied
    case notificationCenterNotRunning
    case barkRejected(statusCode: Int, body: String)

    var description: String {
        switch self {
        case .missingDeviceKey:
            return "缺少 Bark 设备 Key。请传入 --device-key，或设置 BARK_DEVICE_KEY。"
        case .invalidBarkBaseURL(let value):
            return "无效的 Bark 服务地址：\(value)"
        case .invalidPollInterval(let value):
            return "无效的轮询间隔：\(value)"
        case .invalidFieldValue(let field, let reason):
            return "\(field) 配置无效：\(reason)"
        case .invalidOption(let value):
            return "未知参数：\(value)"
        case .invalidFixturePath(let value):
            return "夹具文件不存在：\(value)"
        case .invalidConfigurationFile(let path, let reason):
            return "配置文件无效：\(path)，原因：\(reason)"
        case .missingBundledTemplate:
            return "应用包里缺少默认配置模板。"
        case .accessibilityPermissionDenied:
            return "需要辅助功能权限。请在“系统设置 > 隐私与安全性 > 辅助功能”里启用日志中显示的 app 或可执行文件。"
        case .notificationCenterNotRunning:
            return "通知中心进程未运行。"
        case .barkRejected(let statusCode, let body):
            return "Bark 请求失败，状态码 \(statusCode)：\(body)"
        }
    }
}

func describe(_ error: Error) -> String {
    if let bridgeError = error as? BridgeError {
        return bridgeError.description
    }
    return error.localizedDescription
}

func currentProcessLogContext() -> String {
    let executablePath = ProcessInfo.processInfo.arguments.first ?? "-"
    let bundlePath = Bundle.main.bundleURL.path
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "-"

    return "bundleID=\(bundleIdentifier) bundlePath=\(bundlePath) executablePath=\(executablePath)"
}

extension String {
    var fingerprint: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

extension Sequence where Element == String {
    func stableUniqued() -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for item in self {
            let key = item.fingerprint
            guard !key.isEmpty, seen.insert(key).inserted else {
                continue
            }
            output.append(item)
        }

        return output
    }
}

extension AccessibilityNode {
    var totalNodeCount: Int {
        1 + children.reduce(0) { $0 + $1.totalNodeCount }
    }

    var notificationPanelVisible: Bool {
        children.contains { $0.role == "AXWindow" }
    }
}
