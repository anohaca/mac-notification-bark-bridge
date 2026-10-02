import AppKit
import Foundation

@MainActor
final class ConfigurationWindowController: NSWindowController, NSWindowDelegate {
    private let configurationStore: ConfigurationStore
    private let onSave: (StoredConfiguration) throws -> Void
    private let onClose: () -> Void

    private let deviceKeyField = NSTextField(string: "")
    private let barkBaseURLField = NSTextField(string: "")
    private let sourceFilterField = NSTextField(string: "")
    private let pollIntervalField = NSTextField(string: "")
    private let dedupeWindowField = NSTextField(string: "")
    private let dryRunButton = NSButton(checkboxWithTitle: "仅调试，不发送 Bark", target: nil, action: nil)
    private let promptAccessibilityButton = NSButton(
        checkboxWithTitle: "需要时请求辅助功能权限",
        target: nil,
        action: nil
    )
    private let launchAtLoginButton = NSButton(
        checkboxWithTitle: "登录 macOS 时自动启动",
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(
        configurationStore: ConfigurationStore,
        onSave: @escaping (StoredConfiguration) throws -> Void,
        onClose: @escaping () -> Void
    ) {
        self.configurationStore = configurationStore
        self.onSave = onSave
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 450),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac 通知 Bark 转发"
        window.center()

        super.init(window: window)

        window.delegate = self
        window.contentView = buildContentView()
        loadFromDisk()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        loadFromDisk()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    private func buildContentView() -> NSView {
        deviceKeyField.placeholderString = "你的 Bark 设备 Key"
        barkBaseURLField.placeholderString = "https://api.day.app"
        sourceFilterField.placeholderString = "消息、Slack、邮件…"
        pollIntervalField.placeholderString = "2"
        dedupeWindowField.placeholderString = "300"

        let introLabel = NSTextField(wrappingLabelWithString:
            "在这里修改转发配置。保存后会重写配置文件，并立即重新加载监听状态。"
        )
        introLabel.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [label("Bark 设备 Key"), deviceKeyField],
            [label("Bark 服务地址"), barkBaseURLField],
            [label("来源过滤"), sourceFilterField],
            [label("轮询间隔（秒）"), pollIntervalField],
            [label("去重窗口（秒）"), dedupeWindowField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.xPlacement = .leading
        grid.row(at: 0).topPadding = 0

        for rowIndex in 0..<5 {
            grid.cell(atColumnIndex: 0, rowIndex: rowIndex).xPlacement = .trailing
        }

        let toggles = NSStackView(views: [dryRunButton, promptAccessibilityButton, launchAtLoginButton])
        toggles.orientation = .vertical
        toggles.spacing = 8

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveConfiguration(_:)))
        saveButton.keyEquivalent = "\r"

        let reloadButton = NSButton(title: "从磁盘重载", target: self, action: #selector(reloadFromDiskAction(_:)))
        let revealButton = NSButton(title: "打开配置文件", target: self, action: #selector(openConfigurationFile(_:)))

        let buttonRow = NSStackView(views: [saveButton, reloadButton, revealButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let contentStack = NSStackView(views: [introLabel, grid, toggles, statusLabel, buttonRow])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16

        let contentView = NSView()
        contentView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            deviceKeyField.widthAnchor.constraint(equalToConstant: 320),
            barkBaseURLField.widthAnchor.constraint(equalToConstant: 320),
            sourceFilterField.widthAnchor.constraint(equalToConstant: 320),
            pollIntervalField.widthAnchor.constraint(equalToConstant: 120),
            dedupeWindowField.widthAnchor.constraint(equalToConstant: 120),
        ])

        return contentView
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        field.textColor = .labelColor
        return field
    }

    private func loadFromDisk() {
        do {
            let stored = try configurationStore.loadStoredConfiguration()
            populateFields(with: stored.normalized())

            let configURL = try configurationStore.configurationURL()
            showStatus(
                "正在编辑 \(NSString(string: configURL.path).abbreviatingWithTildeInPath)",
                color: .secondaryLabelColor
            )
        } catch {
            populateFields(with: .defaults)
            showStatus(
                "无法读取当前配置，表单已填入默认值。保存后可修复配置文件。",
                color: .systemOrange
            )
        }
    }

    func populateFields(with stored: StoredConfiguration) {
        let normalized = stored.normalized()
        deviceKeyField.stringValue = normalized.deviceKey ?? ""
        barkBaseURLField.stringValue = normalized.barkBaseURL ?? StoredConfiguration.defaults.barkBaseURL ?? ""
        sourceFilterField.stringValue = normalized.sourceFilter ?? ""
        pollIntervalField.stringValue = formatNumber(normalized.pollInterval ?? 2)
        dedupeWindowField.stringValue = formatNumber(normalized.dedupeWindow ?? 300)
        dryRunButton.state = normalized.dryRun == true ? .on : .off
        promptAccessibilityButton.state = normalized.promptForAccessibility == false ? .off : .on
        launchAtLoginButton.state = normalized.launchAtLogin == true ? .on : .off
    }

    private func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    func currentFormConfiguration() throws -> StoredConfiguration {
        StoredConfiguration(
            deviceKey: deviceKeyField.stringValue,
            barkBaseURL: barkBaseURLField.stringValue,
            sourceFilter: sourceFilterField.stringValue,
            pollInterval: try parseNumber(
                from: pollIntervalField.stringValue,
                fieldName: "轮询间隔",
                defaultValue: StoredConfiguration.defaults.pollInterval ?? 2
            ),
            dryRun: dryRunButton.state == .on,
            promptForAccessibility: promptAccessibilityButton.state == .on,
            dedupeWindow: try parseNumber(
                from: dedupeWindowField.stringValue,
                fieldName: "去重窗口",
                defaultValue: StoredConfiguration.defaults.dedupeWindow ?? 300
            ),
            launchAtLogin: launchAtLoginButton.state == .on
        )
    }

    private func parseNumber(from string: String, fieldName: String, defaultValue: Double) throws -> Double {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultValue
        }

        guard let number = Double(trimmed) else {
            throw BridgeError.invalidFieldValue(
                field: fieldName,
                reason: "请输入数字。"
            )
        }

        return number
    }

    private func showStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }

    var statusTextForTesting: String {
        statusLabel.stringValue
    }

    func saveCurrentForm() throws {
        let stored = try currentFormConfiguration()
        try configurationStore.save(stored)
        try onSave(stored.normalized())
        showStatus("已保存，监听状态已重新加载。", color: .systemGreen)
    }

    @objc private func saveConfiguration(_ sender: Any?) {
        do {
            try saveCurrentForm()
        } catch {
            let message: String
            if let bridgeError = error as? BridgeError {
                message = bridgeError.description
            } else {
                message = error.localizedDescription
            }
            showStatus(message, color: .systemRed)
        }
    }

    @objc private func reloadFromDiskAction(_ sender: Any?) {
        loadFromDisk()
    }

    @objc private func openConfigurationFile(_ sender: Any?) {
        do {
            let url = try configurationStore.configurationURL()
            NSWorkspace.shared.open(url)
        } catch {
            showStatus(error.localizedDescription, color: .systemRed)
        }
    }
}
