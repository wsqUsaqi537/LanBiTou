import Darwin
import Foundation

enum ReminderRepositoryError: LocalizedError {
    case missingAppGroupIdentifier
    case invalidAppGroupIdentifier
    case invalidStoredValue
    case corruptedData(Error)
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
    private static let snapshotInfoKey = "WidgetSnapshotRelativePath"
    private static let snapshotReadOnlyInfoKey = "WidgetSnapshotReadOnly"
    private static let snapshotRelativePath = "Library/Application Support/com.ban1et.lanbitou/widget-reminders.json"

    private let defaults: UserDefaults?
    private let configurationError: ReminderRepositoryError?
    private let snapshotURL: URL?
    private let isReadOnlySnapshot: Bool

    // The default argument preserves the existing init(defaults:) call site.
    init(defaults: UserDefaults, snapshotURL: URL? = nil) {
        self.defaults = defaults
        configurationError = nil
        self.snapshotURL = snapshotURL
        isReadOnlySnapshot = false
    }

    // Used by the widget's read-only snapshot path and by snapshot fixtures.
    init(snapshotURL: URL) {
        defaults = nil
        configurationError = nil
        self.snapshotURL = snapshotURL
        isReadOnlySnapshot = true
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
            return
        }

        guard let appGroupIdentifier = info["AppGroupIdentifier"] as? String else {
            defaults = nil
            configurationError = .missingAppGroupIdentifier
            snapshotURL = configuredSnapshotURL
            isReadOnlySnapshot = false
            return
        }

        let identifier = appGroupIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !identifier.contains("$(") else {
            defaults = nil
            configurationError = .invalidAppGroupIdentifier
            snapshotURL = configuredSnapshotURL
            isReadOnlySnapshot = false
            return
        }

        guard let sharedDefaults = UserDefaults(suiteName: identifier) else {
            defaults = nil
            configurationError = .invalidAppGroupIdentifier
            snapshotURL = configuredSnapshotURL
            isReadOnlySnapshot = false
            return
        }

        defaults = sharedDefaults
        configurationError = nil
        snapshotURL = configuredSnapshotURL
        isReadOnlySnapshot = false
    }

    func load() throws -> [Reminder] {
        if isReadOnlySnapshot {
            return try loadSnapshot()
        }

        let defaults = try configuredDefaults()
        let reminders: [Reminder]
        if defaults.object(forKey: Self.storageKey) == nil {
            reminders = []
        } else {
            guard let data = defaults.data(forKey: Self.storageKey) else {
                throw ReminderRepositoryError.invalidStoredValue
            }

            do {
                reminders = try JSONDecoder().decode([Reminder].self, from: data)
            } catch {
                throw ReminderRepositoryError.corruptedData(error)
            }
        }

        if let snapshotURL {
            try writeSnapshot(try JSONEncoder().encode(reminders), to: snapshotURL)
        }
        return reminders
    }

    func save(_ reminders: [Reminder]) throws {
        guard !isReadOnlySnapshot else {
            throw ReminderRepositoryError.readOnly
        }

        let defaults = try configuredDefaults()
        let data = try JSONEncoder().encode(reminders)
        if let snapshotURL {
            try writeSnapshot(data, to: snapshotURL)
        }
        defaults.set(data, forKey: Self.storageKey)
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
