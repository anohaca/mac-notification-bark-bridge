# Release vX.Y.Z

## Summary

一句话说明这个版本的重点。

## Added

- 新增了什么
- 新支持了什么场景

## Changed

- 默认行为或使用方式有哪些调整
- 配置、UI、日志、打包流程有哪些变化

## Fixed

- 修复了哪些已知问题
- 解决了哪些兼容性或稳定性问题

## Privacy And Security

- 是否调整了日志脱敏策略
- 是否减少了敏感信息落盘或外发

## Known Limitations

- 仍然依赖哪些系统权限
- 还有哪些通知场景抓不到

## Installation

1. 下载本版本的 zip 资产。
2. 解压得到 `MacNotificationBarkBridge.app`。
3. 启动后在设置窗口填写 Bark Key。
4. 到 `系统设置 > 隐私与安全性 > 辅助功能` 给 app 授权。

## Verification

- `swift test`：通过
- `./scripts/build-app.sh`：通过

## Assets

- `MacNotificationBarkBridge-vX.Y.Z-macos.zip`
