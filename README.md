# 烂笔头

macOS 14 及以上的原生事项记录应用，使用 SwiftUI 和 WidgetKit。

## 下载与图形安装

[直接下载烂笔头 1.0 的 DMG 安装包（约 3.4 MB）](https://github.com/wsqUsaqi537/LanBiTou/releases/download/v1.0.0/LanBiTou-1.0.dmg) · [查看最新版本](https://github.com/wsqUsaqi537/LanBiTou/releases/latest)

支持 macOS 14 及以上的 Apple 芯片和 Intel Mac。下载安装无需终端命令，也无需安装 Xcode。

1. 下载 `LanBiTou-1.0.dmg`，双击打开。
2. 将“烂笔头.app”拖到“Applications”图标上，等待复制完成。
3. 推出磁盘映像，从“应用程序”文件夹打开“烂笔头”。

此版本使用本机 ad-hoc 签名，未使用 Apple Developer ID 签名，也未经过 Apple 公证，macOS 可能会阻止首次打开。首次尝试打开后，若被阻止且确认来源可信，可前往苹果菜单 >“系统设置”>“隐私与安全性”，在“安全性”区域点击“仍要打开”。请只对你信任的来源授权，详见 [Apple 官方说明](https://support.apple.com/en-us/102445)。

## 桌面小组件

安装后请从“应用程序”打开 **烂笔头**。开发时也可打开项目根目录的 **烂笔头.app**。应用包含 WidgetKit 扩展，可在系统小组件选择器中添加。

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

## 开发者：从源码构建

先退出烂笔头，再在项目根目录运行：

```sh
./build-widget.sh
```

脚本生成“烂笔头.app”，保留原生扩展，逐级进行本机 ad-hoc 签名，并注册到当前用户的扩展服务。构建缓存放在系统临时目录，退出时清理。已有应用在成功构建后才替换，安装或注册失败会恢复旧版本。原 `build-preview.sh` 入口也会转到这个完整构建流程。

此构建用于当前 Mac，不需要开发证书。正式分发时应使用自己的开发签名；生产工程仍保留 App Group 配置。

## 开发者：制作 DMG 安装包

项目根目录已有“烂笔头.app”时，可运行 `./build-dmg.sh` 将当前应用打包为 HFS+、只读压缩的 `LanBiTou-1.0.dmg`，并生成 `LanBiTou-1.0.dmg.sha256`。脚本会检查应用标识、版本和代码签名，在系统临时目录暂存并验证安装包；若同名输出已存在，会停止以避免覆盖。它不会重建或退出正在运行的应用。

## iCloud 同步准备

已准备 Mac 与未来 iPhone 共用的 CloudKit 私有同步代码、离线变更记录和旧数据迁移。事项内容及增删改全部参与同步，冲突按最后操作时间处理。当前未配置开发账号与 iCloud 容器，本机版本显示“iCloud 待配置”，继续保存到本地。

启用步骤、账户隔离和未来 iPhone 接入说明见 [ICLOUD_SETUP.md](ICLOUD_SETUP.md)。真实云端和双设备同步待签名与容器就绪后验证。

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

34 项离线测试覆盖日期边界、时区、夏令时、事项增删改、旧数据迁移、按操作时间合并、删除冲突、待上传状态、只读小组件、CloudKit 记录编码及损坏数据保护。共享代码已通过 iOS 17 类型检查；真实云端同步尚未验证。

DMG 已通过镜像完整性、只读挂载、内嵌 Widget 和代码签名检查，包内应用文件与正式 App 一致，未包含本地事项数据。GitHub 发布附件的大小和 SHA-256 与本地安装包一致；尚未在另一台 Mac 上验证安装和小组件注册。

本机完整构建、嵌套签名、扩展注册均已通过；已在主应用验证原数据读取和快照生成，并由用户在系统选择器中添加到桌面，确认显示测试事项，修改标题和取消截止日期后自动同步。测试事项已清除；脚本的进程检测失败与注册失败回滚另经模拟故障验证。

小组件打开入口使用 SwiftUI 的[外部事件路由](https://developer.apple.com/documentation/swiftui/scene/handlesexternalevents(matching:))处理 `lanbitou://open`，并让现有窗口优先接收链接。通过 Safari 的本机链接入口已验证退出后的启动和最小化恢复，窗口菜单仅显示一个主窗口；用户已实际点击桌面小组件，确认显示主页面，并确认关闭窗口后连续点击两次能够恢复且只有一个窗口。
