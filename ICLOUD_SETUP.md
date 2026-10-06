# iCloud 同步准备

当前正式版仍可在本机记录事项。本机 ad-hoc 构建明确关闭 iCloud，界面显示“本地保存 · iCloud 待配置”；准备好的 CloudKit 代码在容器、签名及开发账号就绪后才能启用。尚未执行真实的云端上传或双设备验证。

## 共享数据和合并规则

Mac 与未来的 iPhone 版使用同一个 CloudKit **私有数据库**、`LanBiTouReminders` zone 和 `ReminderV1` record type。各人的事项保存在自己的 iCloud 账户中。共享代码最低支持 macOS 14 / iOS 17，采用 Apple 的 [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5) 管理变更和重试。

- 标题、备注、可选截止日期以及新增、编辑、删除全部同步。截止日期保存公历年月日，避免跨时区变成另一天。
- 每条事项保留稳定 UUID；每次改变保存 `modifiedAt` 和稳定的 `changeID`。
- 按用户选择，所有操作以最后操作时间为准。删除保存为带版本的空内容记录，较晚的编辑可以使事项重新出现；较早的离线编辑无法覆盖较晚删除。
- 相同时间以 `changeID` 排序，保证两端一致。时间来自设备时钟，应使用系统自动日期和时间；设备时钟偏差仍会影响“最后”的判断。
- 本地变更和待上传状态先保存，网络中断时继续使用本地事项。重启后会恢复待同步项。删除记录暂不清理，保留它们才能比较旧离线操作。
- 首次启用会绑定 iCloud 账户、容器和环境。更换账户、容器或环境时暂停同步并保留本地数据，不会自动将上一账户的数据上传到新账户。

本地新增 `reminders.sync.v1` 文档，包含事项版本、删除记录、待发送状态和引擎状态。旧 `reminders.json` 自动迁移，保留原 UUID、内容、创建时间和截止日期；小组件仍只读取事项数组及本机快照。云端数据合并后会通知主界面并更新小组件。

## 有开发账号后启用

1. 在 Xcode 登录有有效 Apple Developer Program 资格的团队，为 App 和 Widget 配置对应签名与 App Group。按照 Apple 的[启用 CloudKit 指引](https://developer.apple.com/documentation/cloudkit/enabling-cloudkit-in-your-app)，创建属于该团队的 iCloud 容器并将主 App 关联到它。
2. 为主 App 启用 iCloud → CloudKit 和 Push Notifications。工程提供 `App/LanBiTouCloud.entitlements` 模板；Widget 继续读取本地数据，无需直接访问 CloudKit。
3. 在主 App 的构建设置中指定以下值，保留 Widget 自己的签名文件：
   - `LANBITOU_APP_ENTITLEMENTS` = `App/LanBiTouCloud.entitlements`
   - `LANBITOU_ICLOUD_ENABLED` = `YES`
   - `LANBITOU_ICLOUD_CONTAINER` = 该团队实际拥有的容器 ID。默认候选 `iCloud.com.ban1et.lanbitou` 目前尚未注册。
   - `LANBITOU_ICLOUD_ENVIRONMENT` = `Development`
   - `LANBITOU_PUSH_ENVIRONMENT` = `development`
4. 使用有效开发签名构建。`build-widget.sh` 专供当前本机版本，会强制关闭 iCloud；验证云同步时应从 Xcode 运行配置好的开发签名版本。
5. 当前本机版本的数据域为 `com.ban1et.lanbitou.preview.data`，开发签名版本默认使用 App Group 数据域。切换数据域前保留当前本地数据，并安排一次从原数据域到正式 App Group 的迁移；不能仅改变 App Group 标识后就覆盖安装。本次自动迁移指的是同一数据域内旧 JSON 到带版本文档的迁移。

开发与生产环境使用独立的 CloudKit 数据。上架前需部署 schema 至 Production，匹配分发描述文件的 iCloud 和推送环境；当前模板用于开发验证。

## 接入未来 iPhone 版

iPhone 工程可以复用 `Shared/Reminder.swift`、`ReminderSyncState.swift`、`ReminderRepository.swift` 和 `ReminderCloudSync.swift`，并通过 `ReminderCloudSync` 的状态/数据回调刷新界面。两个客户端需保持相同容器、环境、zone、record type 和字段格式。

iPhone 主 App 配置同一 iCloud 容器、CloudKit 和 Push Notifications；iOS 推送 entitlement 使用 `aps-environment`，不能直接复制 Mac 的 `com.apple.developer.aps-environment`。后台接收需要 Remote notifications 能力。iOS 使用自己的 App Group 共享小组件数据，保持 `WidgetSnapshotRelativePath` 未设置，Mac 专用快照路径无需带入 iPhone。

签名和容器就绪后，需用同一 iCloud 账户的 Mac 与 iPhone 验证：首次上传/下载、增删改、无期限事项、离线后重启、两端冲突、截止次日删除、小组件刷新及账户切换。Push 驱动同步应在真实设备上验证。可参考 [Apple CKSyncEngine 示例](https://github.com/apple/sample-cloudkit-sync-engine)。
