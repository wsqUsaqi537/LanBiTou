import Darwin
import Foundation

enum ReminderRepositoryError: LocalizedError {
    case missingAppGroupIdentifier
    case invalidAppGroupIdentifier
    case invalidStoredValue
    case corruptedData(Error)
    case unsupportedSyncSchema(Int)
    case readOnly
    case invalidSnapshotPath
    case snapshotHomeDirectoryUnavailable
    case snapshotReadFailed(Error)
    case snapshotWriteFailed(Error)

    var errorDescription: String? {
        switch self {
        case .missingAppGroupIdentifier:
            return "应用缺少 AppGroupIdentifier 配置，无法打开共享事项存储。"
        case .invalidAppGroupIdentifier:
            return "AppGroupIdentifier 配置无效，无法打开共享事项存储。"
        case .invalidStoredValue:
            return "事项存储格式无效，原有数据已保留。"
        case .corruptedData(let error):
            return "事项数据无法读取，原有数据已保留。\(error.localizedDescription)"
        case .unsupportedSyncSchema(let version):
            return "事项同步数据版本 \(version) 暂不支持，原有数据已保留。"
        case .readOnly:
            return "小组件快照为只读，无法保存事项。"
        case .invalidSnapshotPath:
            return "WidgetSnapshotRelativePath 配置无效，快照路径必须是应用专用的固定相对路径。"
        case .snapshotHomeDirectoryUnavailable:
            return "无法确定当前用户的主目录，不能访问小组件快照。"
        case .snapshotReadFailed(let error):
            return "小组件快照无法读取。\(error.localizedDescription)"
        case .snapshotWriteFailed(let error):
            return "小组件快照无法写入，事项数据未更新。\(error.localizedDescription)"
        }
    }
}

struct ReminderRepository {
    private static let storageKey = "reminders.json"
    private static let syncStorageKey = "reminders.sync.v1"
    private static let syncSchemaVersion = 1
    private static let snapshotInfoKey = "WidgetSnapshotRelativePath"
    private static let snapshotReadOnlyInfoKey = "WidgetSnapshotReadOnly"
    private static let snapshotRelativePath = "Library/Application Support/com.ban1et.lanbitou/widget-reminders.json"

    private let defaults: UserDefaults?
    private let configurationError: ReminderRepositoryError?
    private let snapshotURL: URL?
    private let isReadOnlySnapshot: Bool
    private let isReadOnlyDefaults: Bool

    // The default argument preserves the existing init(defaults:) call site.
    init(defaults: UserDefaults, snapshotURL: URL? = nil, readOnly: Bool = false) {
        self.defaults = defaults
        configurationError = nil
        self.snapshotURL = snapshotURL
        isReadOnlySnapshot = false
        isReadOnlyDefaults = readOnly
    }

    // Used by the widget's read-only snapshot path and by snapshot fixtures.
    init(snapshotURL: URL) {
        defaults = nil
        configurationError = nil
        self.snapshotURL = snapshotURL
        isReadOnlySnapshot = true
        isReadOnlyDefaults = false
    }

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let snapshotConfiguration = Self.snapshotURL(from: info[Self.snapshotInfoKey])
        let readOnlySnapshot = (info[Self.snapshotReadOnlyInfoKey] as? Bool) == true

        if case .failure(let error) = snapshotConfiguration {
            defaults = nil
            configurationError = error
            snapshotURL = nil
            isReadOnlySnapshot = false
            isReadOnlyDefaults = false
            return
        }

        let configuredSnapshotURL: URL?
        if case .success(let url) = snapshotConfiguration {
            configuredSnapshotURL = url
        } else {
            configuredSnapshotURL = nil
        }

        if readOnlySnapshot, let configuredSnapshotURL {
            defaults = nil
            configurationError = nil
            snapshotURL = configuredSnapshotURL
            isReadOnlySnapshot = true
            isReadOnlyDefaults = false
            return
        }

        guard let appGroupIdentifier = info["AppGroupIdentifier"] as? String else {
            defaults = nil
            configurationError = .missingAppGroupIdentifier
            snapshotURL = configuredSnapshotURL
            isReadOnlySnapshot = false
            isReadOnlyDefaults = false
            return
        }

        let identifier = appGroupIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !identifier.contains("$(") else {
            defaults = nil
            configurationError = .invalidAppGroupIdentifier
            snapshotURL = configuredSnapshotURL
            isReadOnlySnapshot = false
            isReadOnlyDefaults = false
            return
        }

        guard let sharedDefaults = UserDefaults(suiteName: identifier) else {
            defaults = nil
            configurationError = .invalidAppGroupIdentifier
            snapshotURL = configuredSnapshotURL
            isReadOnlySnapshot = false
            isReadOnlyDefaults = false
            return
        }

        defaults = sharedDefaults
        configurationError = nil
        snapshotURL = configuredSnapshotURL
        isReadOnlySnapshot = false
        isReadOnlyDefaults = readOnlySnapshot
    }

    func load() throws -> [Reminder] {
        if isReadOnlySnapshot {
            return try loadSnapshot()
        }
        if isReadOnlyDefaults {
            return try readLegacyReminders(from: configuredDefaults())
        }

        let defaults = try configuredDefaults()
        let (state, didMigrate) = try readOrMigrateSyncState(in: defaults)
        let reminders = Self.liveReminders(in: state)
        if !didMigrate, let snapshotURL {
            try writeSnapshot(try Self.snapshotData(for: reminders, at: Date()), to: snapshotURL)
        }
        return reminders
    }

    func loadSyncState() throws -> ReminderSyncState {
        guard !isReadOnlySnapshot, !isReadOnlyDefaults else {
            throw ReminderRepositoryError.readOnly
        }
        let defaults = try configuredDefaults()
        return try readOrMigrateSyncState(in: defaults).state
    }

    func saveSyncState(_ state: ReminderSyncState) throws {
        guard !isReadOnlySnapshot, !isReadOnlyDefaults else {
            throw ReminderRepositoryError.readOnly
        }
        try Self.validate(state)

        let defaults = try configuredDefaults()
        // Do not let a caller replace data that this version cannot decode.
        if defaults.object(forKey: Self.syncStorageKey) != nil {
            _ = try readStoredSyncState(from: defaults)
        } else if defaults.object(forKey: Self.storageKey) != nil {
            _ = try readLegacyReminders(from: defaults)
        }
        try persist(state, at: Date(), in: defaults)
    }

    func mergeCloudRecords(_ incomingEntries: [ReminderSyncEntry]) throws {
        guard !isReadOnlySnapshot, !isReadOnlyDefaults else {
            throw ReminderRepositoryError.readOnly
        }
        try Self.validateEntries(incomingEntries)

        let defaults = try configuredDefaults()
        let localState = try readOrMigrateSyncStateForUpdate(in: defaults)
        var entriesByID = Dictionary(uniqueKeysWithValues: localState.entries.map { ($0.record.id, $0) })

        for incoming in incomingEntries {
            guard let local = entriesByID[incoming.record.id] else {
                entriesByID[incoming.record.id] = ReminderSyncEntry(
                    record: incoming.record,
                    cloudSystemFields: incoming.cloudSystemFields,
                    needsUpload: false
                )
                continue
            }

            if incoming.record.modifiedAt == local.record.modifiedAt,
               incoming.record.changeID == local.record.changeID,
               incoming.record != local.record {
                throw ReminderRepositoryError.invalidStoredValue
            }

            let incomingWins = incoming.record.isNewer(than: local.record) || incoming.record == local.record
            entriesByID[incoming.record.id] = ReminderSyncEntry(
                record: incomingWins ? incoming.record : local.record,
                cloudSystemFields: incoming.cloudSystemFields,
                needsUpload: !incomingWins
            )
        }

        var mergedState = localState
        mergedState.entries = localState.entries.map { entriesByID[$0.record.id]! }
        let existingIDs = Set(localState.entries.map { $0.record.id })
        mergedState.entries.append(contentsOf: incomingEntries.compactMap { entry in
            existingIDs.contains(entry.record.id) ? nil : entriesByID[entry.record.id]
        })
        try persist(mergedState, at: Date(), in: defaults)
    }

    func save(_ reminders: [Reminder], at date: Date = Date()) throws {
        guard !isReadOnlySnapshot, !isReadOnlyDefaults else {
            throw ReminderRepositoryError.readOnly
        }
        try Self.validateReminders(reminders)

        let defaults = try configuredDefaults()
        var state = try readOrMigrateSyncStateForUpdate(in: defaults)
        let requestedByID = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
        var entriesByID = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.record.id, $0) })

        for reminder in reminders {
            let existing = entriesByID[reminder.id]
            if existing?.record.reminder == reminder {
                continue
            }
            entriesByID[reminder.id] = ReminderSyncEntry(
                record: ReminderSyncRecord(id: reminder.id, reminder: reminder, modifiedAt: date, changeID: UUID()),
                cloudSystemFields: existing?.cloudSystemFields,
                needsUpload: true
            )
        }

        for existing in state.entries where existing.record.reminder != nil && requestedByID[existing.record.id] == nil {
            entriesByID[existing.record.id] = ReminderSyncEntry(
                record: ReminderSyncRecord(id: existing.record.id, reminder: nil, modifiedAt: date, changeID: UUID()),
                cloudSystemFields: existing.cloudSystemFields,
                needsUpload: true
            )
        }

        let existingIDs = Set(state.entries.map { $0.record.id })
        state.entries = state.entries.map { entriesByID[$0.record.id]! }
        state.entries.append(contentsOf: reminders.compactMap { reminder in
            existingIDs.contains(reminder.id) ? nil : entriesByID[reminder.id]
        })
        try persist(state, at: date, in: defaults)
    }

    private func readOrMigrateSyncState(in defaults: UserDefaults) throws -> (state: ReminderSyncState, didMigrate: Bool) {
        if defaults.object(forKey: Self.syncStorageKey) != nil {
            return (try readStoredSyncState(from: defaults), false)
        }

        let state = try Self.initialState(from: readLegacyReminders(from: defaults))
        let stateData = try JSONEncoder().encode(state)
        let snapshotData = try Self.snapshotData(for: Self.liveReminders(in: state), at: Date())
        if let snapshotURL {
            try writeSnapshot(snapshotData, to: snapshotURL)
        }
        defaults.set(stateData, forKey: Self.syncStorageKey)
        return (state, true)
    }

    private func readOrMigrateSyncStateForUpdate(in defaults: UserDefaults) throws -> ReminderSyncState {
        if defaults.object(forKey: Self.syncStorageKey) != nil {
            return try readStoredSyncState(from: defaults)
        }
        return try Self.initialState(from: readLegacyReminders(from: defaults))
    }

    private func readStoredSyncState(from defaults: UserDefaults) throws -> ReminderSyncState {
        guard let data = defaults.data(forKey: Self.syncStorageKey) else {
            throw ReminderRepositoryError.invalidStoredValue
        }

        let state: ReminderSyncState
        do {
            state = try JSONDecoder().decode(ReminderSyncState.self, from: data)
        } catch {
            throw ReminderRepositoryError.corruptedData(error)
        }
        try Self.validate(state)
        return state
    }

    private func readLegacyReminders(from defaults: UserDefaults) throws -> [Reminder] {
        guard defaults.object(forKey: Self.storageKey) != nil else { return [] }
        guard let data = defaults.data(forKey: Self.storageKey) else {
            throw ReminderRepositoryError.invalidStoredValue
        }

        do {
            let reminders = try JSONDecoder().decode([Reminder].self, from: data)
            try Self.validateReminders(reminders)
            return reminders
        } catch let error as ReminderRepositoryError {
            throw error
        } catch {
            throw ReminderRepositoryError.corruptedData(error)
        }
    }

    private func persist(_ state: ReminderSyncState, at date: Date, in defaults: UserDefaults) throws {
        try Self.validate(state)
        let stateData = try JSONEncoder().encode(state)
        let liveReminders = Self.liveReminders(in: state)
        let legacyData = try JSONEncoder().encode(liveReminders)
        let snapshotData = try Self.snapshotData(for: liveReminders, at: date)

        if let snapshotURL {
            try writeSnapshot(snapshotData, to: snapshotURL)
        }
        defaults.set(stateData, forKey: Self.syncStorageKey)
        defaults.set(legacyData, forKey: Self.storageKey)
    }

    private static func initialState(from reminders: [Reminder]) throws -> ReminderSyncState {
        try validateReminders(reminders)
        return ReminderSyncState(entries: reminders.map { reminder in
            ReminderSyncEntry(
                record: ReminderSyncRecord(
                    id: reminder.id,
                    reminder: reminder,
                    modifiedAt: reminder.createdAt,
                    changeID: UUID()
                ),
                cloudSystemFields: nil,
                needsUpload: true
            )
        })
    }

    private static func liveReminders(in state: ReminderSyncState) -> [Reminder] {
        state.entries.compactMap { $0.record.reminder }
    }

    private static func snapshotData(for reminders: [Reminder], at date: Date) throws -> Data {
        try JSONEncoder().encode(Reminder.visible(from: reminders, at: date))
    }

    private static func validate(_ state: ReminderSyncState) throws {
        guard state.schemaVersion == syncSchemaVersion else {
            throw ReminderRepositoryError.unsupportedSyncSchema(state.schemaVersion)
        }
        try validateEntries(state.entries)
    }

    private static func validateEntries(_ entries: [ReminderSyncEntry]) throws {
        var ids = Set<UUID>()
        for entry in entries {
            guard ids.insert(entry.record.id).inserted,
                  entry.record.reminder?.id == nil || entry.record.reminder?.id == entry.record.id else {
                throw ReminderRepositoryError.invalidStoredValue
            }
        }
    }

    private static func validateReminders(_ reminders: [Reminder]) throws {
        var ids = Set<UUID>()
        for reminder in reminders where !ids.insert(reminder.id).inserted {
            throw ReminderRepositoryError.invalidStoredValue
        }
    }

    private func loadSnapshot() throws -> [Reminder] {
        guard let snapshotURL else {
            throw ReminderRepositoryError.invalidSnapshotPath
        }

        let data: Data
        do {
            data = try Data(contentsOf: snapshotURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw ReminderRepositoryError.snapshotReadFailed(error)
        }

        do {
            return try JSONDecoder().decode([Reminder].self, from: data)
        } catch {
            throw ReminderRepositoryError.corruptedData(error)
        }
    }

    private func writeSnapshot(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw ReminderRepositoryError.snapshotWriteFailed(error)
        }
    }

    private static func snapshotURL(from value: Any?) -> Result<URL?, ReminderRepositoryError> {
        guard let path = value as? String else {
            return .success(nil)
        }

        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unset or unexpanded build setting keeps the AppGroup behavior.
        guard !trimmedPath.isEmpty, !trimmedPath.contains("$(") else {
            return .success(nil)
        }

        guard !trimmedPath.hasPrefix("/"),
              trimmedPath == snapshotRelativePath,
              !trimmedPath.split(separator: "/").contains("..") else {
            return .failure(.invalidSnapshotPath)
        }

        guard let passwordEntry = getpwuid(getuid()) else {
            return .failure(.snapshotHomeDirectoryUnavailable)
        }
        let homePath = String(cString: passwordEntry.pointee.pw_dir)
        let homeURL = URL(fileURLWithPath: homePath, isDirectory: true)
        return .success(homeURL.appendingPathComponent(trimmedPath))
    }

    private func configuredDefaults() throws -> UserDefaults {
        guard let defaults else {
            throw configurationError ?? ReminderRepositoryError.invalidAppGroupIdentifier
        }
        return defaults
    }
}
