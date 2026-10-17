import AppKit
@preconcurrency import ApplicationServices
import Foundation

struct PasswordPrompt: Equatable, Sendable {
    let id: String
    let processID: Int32
    let applicationName: String

    var notification: ForwardedNotification {
        ForwardedNotification(
            source: applicationName,
            title: "Mac 需要密码或授权",
            body: "检测到密码或系统授权弹窗，请回到 Mac 处理。",
            identifier: id
        )
    }
}

struct PasswordPromptSnapshot: Sendable {
    let prompts: [PasswordPrompt]
    // Failed/incomplete reads must not be mistaken for a closed window.
    let uncertainProcessIDs: Set<Int32>
}

protocol PasswordPromptProviding: Sendable {
    func snapshot() async throws -> PasswordPromptSnapshot
}

struct PasswordPromptClassifier: Sendable {
    func matches(_ node: AccessibilityNode, isAuthorizationAgent: Bool = false) -> Bool {
        if isAuthorizationAgent && node.role == "AXWindow" {
            return true
        }
        let isDialog = node.role == "AXSheet"
            || node.subrole == "AXDialog" || node.subrole == "AXSystemDialog"
        if isDialog && containsSecureField(node) {
            return true
        }
        return node.children.contains { matches($0) }
    }

    private func containsSecureField(_ node: AccessibilityNode) -> Bool {
        node.subrole == "AXSecureTextField" || node.children.contains { containsSecureField($0) }
    }
}

struct PasswordPromptTracker: Sendable {
    private var sent: [String: Int32] = [:]

    mutating func pending(in snapshot: PasswordPromptSnapshot) -> [PasswordPrompt] {
        let visibleIDs = Set(snapshot.prompts.map(\.id))
        sent = sent.filter { visibleIDs.contains($0.key) || snapshot.uncertainProcessIDs.contains($0.value) }
        var uniqueIDs = Set<String>()
        return snapshot.prompts.filter { sent[$0.id] == nil && uniqueIDs.insert($0.id).inserted }
    }

    mutating func markSent(_ prompt: PasswordPrompt) {
        sent[prompt.id] = prompt.processID
    }
}

struct AccessibilityPasswordPromptProvider: PasswordPromptProviding {
    func snapshot() async throws -> PasswordPromptSnapshot {
        guard await AccessibilityPermissionSupport.isTrusted(prompt: false) else {
            throw BridgeError.accessibilityPermissionDenied
        }
        let applications = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app -> PromptApplication? in
                guard !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    return nil
                }
                let name = app.localizedName ?? app.bundleIdentifier ?? "应用"
                let executable = app.executableURL?.lastPathComponent ?? ""
                let isAgent = app.bundleIdentifier?.hasPrefix("com.apple.") == true
                    && ["SecurityAgent", "SecurityUIAgent", "coreautha"].contains(executable)
                guard app.activationPolicy != .prohibited || isAgent else { return nil }
                return PromptApplication(pid: app.processIdentifier, name: name, isAgent: isAgent)
            }
        }
        var prompts: [PasswordPrompt] = []
        var uncertain = Set<Int32>()
        for app in applications {
            try Task.checkCancellation()
            let root = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(root, 0.05)
            var complete = true
            let windows = elements(kAXWindowsAttribute, from: root, complete: &complete)
            for window in windows {
                var budget = 400
                let tree = metadata(window, depth: 0, budget: &budget, deadline: Date().addingTimeInterval(0.25), complete: &complete)
                if PasswordPromptClassifier().matches(tree, isAuthorizationAgent: app.isAgent) {
                    prompts.append(PasswordPrompt(
                        id: "\(app.pid):\(CFHash(window))", processID: app.pid, applicationName: app.name
                    ))
                }
            }
            if !complete { uncertain.insert(app.pid) }
        }
        try Task.checkCancellation()
        return PasswordPromptSnapshot(prompts: prompts, uncertainProcessIDs: uncertain)
    }

    // Read structural attributes only. Never request AXValue, titles, descriptions, or text.
    private func metadata(
        _ element: AXUIElement, depth: Int, budget: inout Int, deadline: Date, complete: inout Bool
    ) -> AccessibilityNode {
        guard depth < 14, budget > 0, Date() < deadline, !Task.isCancelled else {
            complete = false
            return AccessibilityNode()
        }
        budget -= 1
        let role = attribute(kAXRoleAttribute, from: element, complete: &complete) as? String
        let subrole = attribute(kAXSubroleAttribute, from: element, complete: &complete) as? String
        if subrole == "AXSecureTextField" {
            return AccessibilityNode(role: role, subrole: subrole)
        }
        let modal = attribute(kAXModalAttribute, from: element, complete: &complete) as? Bool ?? false
        let children = elements(kAXChildrenAttribute, from: element, complete: &complete)
        var nodes: [AccessibilityNode] = []
        for child in children {
            guard budget > 0, Date() < deadline, !Task.isCancelled else { complete = false; break }
            nodes.append(metadata(child, depth: depth + 1, budget: &budget, deadline: deadline, complete: &complete))
        }
        return AccessibilityNode(role: role, subrole: modal ? "AXDialog" : subrole, children: nodes)
    }

    private func attribute(_ name: String, from element: AXUIElement, complete: inout Bool) -> CFTypeRef? {
        guard !Task.isCancelled else { complete = false; return nil }
        AXUIElementSetMessagingTimeout(element, 0.05)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result == .success { return value }
        if result != .attributeUnsupported && result != .noValue { complete = false }
        return nil
    }

    private func elements(_ name: String, from element: AXUIElement, complete: inout Bool) -> [AXUIElement] {
        attribute(name, from: element, complete: &complete) as? [AXUIElement] ?? []
    }
}

private struct PromptApplication: Sendable {
    let pid: Int32
    let name: String
    let isAgent: Bool
}
