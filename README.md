# 烂笔头

macOS 14 及以上的原生事项记录应用，使用 SwiftUI 和 WidgetKit。

## 桌面小组件

请打开项目根目录的 **烂笔头.app**。这份本机版本包含真正的 WidgetKit 扩展，可在系统小组件选择器中添加。

1. 先打开应用，记录需要展示的事项。
2. 在桌面空白处右键，选择“编辑小组件”。
3. 搜索“烂笔头”，选择小、中、大尺寸，添加到桌面。
4. 点击小组件可打开主页面；应用在后台或窗口最小化时会恢复并置前，窗口关闭或应用退出后会重新打开。重复点击复用已有窗口。新增、编辑和删除事项后会请求系统更新小组件。

项目仅保留“烂笔头.app”，后续修改和构建均更新这份正式应用。原有事项数据继续沿用，无需手动迁移。

## 事项规则

- 支持标题、备注以及可选截止日期。
- 截止日期按本地公历日期计算，当天保留，次日过期。
- 不设截止日期的事项长期保留。
- 主应用在启动、激活、唤醒和午夜检查过期数据。
- 小组件预先生成日期变化的时间线。应用退出时不会后台常驻删除，存储中的过期记录下次运行时清理；小组件会过滤过期记录，具体刷新由 macOS 调度。

## 本机构建

先退出烂笔头，再在项目根目录运行：

```sh
./build-widget.sh
```

脚本生成“烂笔头.app”，保留原生扩展，逐级进行本机 ad-hoc 签名，并注册到当前用户的扩展服务。构建缓存放在系统临时目录，退出时清理。已有应用在成功构建后才替换，安装或注册失败会恢复旧版本。原 `build-preview.sh` 入口也会转到这个完整构建流程。

此构建用于当前 Mac，不需要开发证书。正式分发时应使用自己的开发签名；生产工程仍保留 App Group 配置。

## 本地数据共享

主应用沿用 UserDefaults 数据域 `com.ban1et.lanbitou.preview.data`，保存的 JSON 键为 `reminders.json`。主应用成功读取或保存后，将同一份数据原子写入：

```text
~/Library/Application Support/com.ban1et.lanbitou/widget-reminders.json
```

本机 Widget 保留 App Sandbox，只获准读取这一个快照文件，不会修改事项。读取或写入错误会显式报告；写快照失败时不覆盖原有事项存储。此方式使用 Apple 文档中的[特定文件只读沙盒例外](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)，避免本机调试依赖 App Group 的开发描述文件。

默认 Xcode 工程不启用快照路径，继续通过 App Group 共享数据。应用与扩展需选择同一签名 Team，并保持 `LANBITOU_APP_GROUP` 一致。本机脚本通过 `LANBITOU_WIDGET_SNAPSHOT_PATH` 启用快照模式。

## 验证

```sh
./Tests/run-tests.sh
```

18 项测试覆盖日期边界、时区、夏令时、排序、编码、事项增删改、只读快照、首次读取已有数据时导出，以及损坏数据与写入失败保护。

本机完整构建、嵌套签名、扩展注册均已通过；已在主应用验证原数据读取和快照生成，并由用户在系统选择器中添加到桌面，确认显示测试事项，修改标题和取消截止日期后自动同步。测试事项已清除；脚本的进程检测失败与注册失败回滚另经模拟故障验证。

小组件打开入口使用 SwiftUI 的[外部事件路由](https://developer.apple.com/documentation/swiftui/scene/handlesexternalevents(matching:))处理 `lanbitou://open`，并让现有窗口优先接收链接。通过 Safari 的本机链接入口已验证退出后的启动和最小化恢复，窗口菜单仅显示一个主窗口；用户已实际点击桌面小组件，确认显示主页面，并确认关闭窗口后连续点击两次能够恢复且只有一个窗口。
