# Mac Notification Bark Bridge

一个运行在 macOS 上的 Swift 菜单栏后台工具。

它会读取当前可见的通知中心内容，提取通知的来源、标题和正文，再通过 Bark 转发到 iPhone。

适合这类场景：

- 你想把 Mac 上某些应用的系统通知同步到 iPhone
- 你希望常驻菜单栏运行，而不是每次手动执行脚本
- 你需要一个可以本地调试、查看日志、查看抓取快照的 Swift 实现

当前有两种运行形态：

1. 无参数启动时，它是一个 `LSUIElement` 菜单栏后台 app。
2. 带命令行参数启动时，它仍然可以作为 CLI 工具做一次性扫描和调试。

## 用途说明

这个项目不是通过私有 API “订阅系统通知”，而是通过辅助功能读取通知中心当前已经展示出来的 UI。

这意味着：

- 它能处理多数普通通知转发场景
- 它依赖辅助功能权限
- 它不会主动替你展开通知中心
- 如果通知中心当前没有展开，就只能看到系统当前暴露出来的节点，可能匹配不到通知

## 方案边界

`UNUserNotificationCenter` 只能管理你自己应用的通知，不能直接订阅其它应用的系统通知。所以如果目标是“检测别的应用发出的系统通知”，可行的公开方案通常是：

1. 给你的程序打开 `Accessibility` 权限。
2. 通过 `AXUIElementCreateApplication` 连接 `NotificationCenter` 进程。
3. 递归读取当前已经显示出来的通知 UI 文本节点。
4. 用启发式规则提取 `来源 / 标题 / 正文`。
5. 对结果去重后调用 Bark API。

## 菜单栏 App

先打包：

```bash
./scripts/build-app.sh
```

默认会生成一个带固定 bundle identifier requirement 的本地 ad-hoc 签名 `.app`，这样 `Accessibility` 授权可以按 `local.codex.MacNotificationBarkBridge` 复用，而不是跟着每次构建变化的 `cdhash` 走。
如果你明确要用自己的签名证书，可以这样打包：

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name" ./scripts/build-app.sh
```

打包结果会输出到：

```bash
build/MacNotificationBarkBridge.app
```

这个 `.app` 带有 `LSUIElement = true`，所以启动后不会出现在 Dock，只会出现在菜单栏。

第一次启动后，程序会在这里生成配置文件：

```text
~/Library/Application Support/MacNotificationBarkBridge/config.json
```

菜单栏里有这些操作：

- `设置…`
- `授权辅助功能…`
- `重新加载配置`
- `打开配置文件`
- `打开日志文件`
- `打开最近快照`
- `立即扫描`
- `开始监听` / `停止监听`
- `退出`

`设置…` 会打开原生配置窗口，你可以直接编辑 Bark key、过滤器、轮询间隔、去重窗口和调试选项。保存后 app 会立即重载配置。

日志和最近一次辅助功能树快照会写到：

```text
~/Library/Application Support/MacNotificationBarkBridge/Logs/bridge.log
~/Library/Application Support/MacNotificationBarkBridge/Logs/latest-tree.json
```

默认情况下，`bridge.log` 不会记录通知正文，只会记录来源、标题和正文长度。
但 `latest-tree.json` 仍然是原始辅助功能快照，可能包含完整通知内容；如果你要分享这个文件，请先自行脱敏。

配置文件示例：

```json
{
  "deviceKey": "YOUR_BARK_KEY",
  "barkBaseURL": "https://api.day.app",
  "sourceFilter": "Messages",
  "pollInterval": 2,
  "dedupeWindow": 300,
  "dryRun": false,
  "promptForAccessibility": true
}
```

如果 `deviceKey` 还是空，菜单栏 app 会保持运行，但状态会提示你去配置文件里补齐 Bark key。

## CLI 调试模式

```bash
swift run mac-notification-bark-bridge \
  --device-key YOUR_BARK_KEY \
  --source-filter Messages
```

第一次运行会请求辅助功能权限。去 `系统设置 > 隐私与安全性 > 辅助功能` 把这个固定路径的 app 勾上：

```text
build/MacNotificationBarkBridge.app
```

菜单栏 app 不会主动展开 `Notification Center`。它只扫描系统当前已经显示出来的通知界面；如果通知中心本身没有展开，它不会替你点开。

只做单次扫描：

```bash
swift run mac-notification-bark-bridge \
  --device-key YOUR_BARK_KEY \
  --source-filter Messages \
  --once
```

只观察，不发 Bark：

```bash
swift run mac-notification-bark-bridge \
  --device-key test \
  --dry-run \
  --dump-tree \
  --once
```

使用夹具验证解析逻辑：

```bash
swift run mac-notification-bark-bridge \
  --device-key test \
  --fixture Tests/MacNotificationBarkBridgeTests/Fixtures/sample-notification-tree.json \
  --dry-run \
  --once
```

也可以显式强制进入菜单栏模式：

```bash
swift run mac-notification-bark-bridge --menu-bar
```

## Bark 调用

这里用的是 Bark 的 `POST /<deviceKey>` 方式，表单字段里带 `title/body/group/level/isArchive`。

## 可靠性建议

- 真机上先用 `--dump-tree --once` 看你机器的通知中心树结构，再按实际文本布局微调 `NotificationParser.swift` 的规则。
- 如果你只关心某个应用，优先用 `--source-filter` 缩小误判范围。
- 同一条通知可能同时出现在横幅和通知中心里，所以需要做去重。
