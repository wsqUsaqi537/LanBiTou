import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum TestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure.expectation(message) }
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0,
    _ minute: Int = 0,
    _ second: Int = 0,
    calendar: Calendar = utcCalendar()
) throws -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    guard let result = calendar.date(from: components) else {
        throw TestFailure.expectation("无法构造日期 \(year)-\(month)-\(day) \(hour):\(minute):\(second)")
    }
    return result
}

private func reminder(
    _ title: String,
    id: UUID,
    due: DueDate? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 0),
    notes: String = ""
) -> Reminder {
    Reminder(id: id, title: title, notes: notes, dueDate: due, createdAt: createdAt)
}

/// Keeps repository tests entirely in memory; no standard or app-group defaults domain is touched.
private final class MemoryUserDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    var template = Array("/tmp/reminder-snapshot-tests.XXXXXX".utf8CString)
    let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
        guard let baseAddress = buffer.baseAddress, mkdtemp(baseAddress) != nil else {
            return nil
        }
        return String(cString: baseAddress)
    }
    guard let path else {
        throw TestFailure.expectation("无法在/tmp创建快照测试临时目录")
    }

    let directory = URL(fileURLWithPath: path, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

@main
private struct ReminderTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("截止日23:59:59仍有效，次日零点过期", testEndOfDueDateAndNextMidnight),
            ("可见事项过滤过期项并保留无期限项", testVisibleFiltering),
            ("月末、年末和闰日按公历排序", testGregorianBoundaries),
            ("夏令时23小时和25小时日期按日历日判断", testDaylightSavingDays),
            ("时区变化不改变已存年月日", testTimeZoneChangePreservesCivilDate),
            ("事项按截止日、创建时间和ID稳定排序", testReminderSorting),
            ("事项与年月日截止日期可编码往返", testCodableRoundTrip),
            ("仓库可保存并读取事项", testRepositorySaveAndLoad),
            ("仓库保存后的新增、编辑和删除可读取", testRepositoryCreateEditDelete),
            ("首次迁移保留事项内容、ID和legacy原字节", testSyncMigrationPreservesLegacyData),
            ("未变事项load和save不生成新版本", testUnchangedReminderKeepsVersion),
            ("离线删除压过更早编辑且更晚编辑可恢复", testOfflineDeleteAndLaterEditMerge),
            ("同时间按changeID字典序稳定选择版本", testSyncTieBreakIsStable),
            ("旧上传确认不会清除较新的本地修改", testOldUploadAcknowledgementKeepsNewLocalEdit),
            ("删除墓碑重启后保留且快照不含已删除项", testTombstonePersistsAndSnapshotOmitsDeleted),
            ("坏同步文档和未知schema不会覆盖数据", testInvalidSyncStateIsPreserved),
            ("同步状态与合并写快照失败时不改任何defaults键", testSyncSnapshotFailuresPreserveDefaults),
            ("重复事项ID和不一致记录ID会被拒绝", testInvalidSyncIdentifiersAreRejected),
            ("相同版本键的冲突payload会拒绝合并", testConflictingPayloadForSameVersionIsRejected),
            ("只读defaults模式读取legacy但不迁移或写入", testReadOnlyDefaultsDoesNotMigrate),
            ("读取损坏数据会报错且保留原字节", testCorruptedDataIsPreserved),
            ("主仓库保存、编辑和删除会同步到只读快照", testSnapshotTracksHostChanges),
            ("首次读取legacy事项会导出快照且不改原数据", testLegacyLoadExportsSnapshot),
            ("快照写入失败时不更新主仓库数据", testSnapshotWriteFailurePreservesDefaults),
            ("只读快照仓库拒绝保存且不改文件", testReadOnlySnapshotRejectsSave),
            ("读取损坏快照会报错且保留原字节", testCorruptedSnapshotIsPreserved),
            ("损坏的legacy数据不会覆盖已有快照", testCorruptedLegacyDataPreservesSnapshot),
            ("缺失快照和显式空数组按接口语义读取", testMissingAndEmptySnapshotSemantics),
            ("无效公历日期无法解码", testInvalidCivilDateRejected)
        ]

        var failures = 0
        for (name, run) in tests {
            do {
                try run()
                print("PASS \(name)")
            } catch {
                failures += 1
                fputs("FAIL \(name): \(error)\n", stderr)
            }
        }

        print("\(tests.count) tests, \(tests.count - failures) passed, \(failures) failed")
        if failures > 0 { exit(EXIT_FAILURE) }
    }

    private static func testEndOfDueDateAndNextMidnight() throws {
        let calendar = utcCalendar()
        let due = DueDate(date: try date(2025, 6, 15, calendar: calendar), calendar: calendar)
        let lastSecond = try date(2025, 6, 15, 23, 59, 59, calendar: calendar)
        let nextMidnight = try date(2025, 6, 16, calendar: calendar)

        try expect(!due.isExpired(at: lastSecond, calendar: calendar), "截止日最后一秒不应过期")
        try expect(due.isExpired(at: nextMidnight, calendar: calendar), "次日零点应已过期")
    }

    private static func testVisibleFiltering() throws {
        let calendar = Calendar.current
        let today = DueDate(date: Date(), calendar: calendar)
        let currentDay = today.date(calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: currentDay)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: currentDay)!
        let noDeadline = reminder("无期限", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let expired = reminder("已过期", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, due: DueDate(date: yesterday, calendar: calendar))
        let dueToday = reminder("今天截止", id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, due: today)
        let future = reminder("未来截止", id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, due: DueDate(date: tomorrow, calendar: calendar))

        let visible = Reminder.visible(from: [expired, future, noDeadline, dueToday], at: Date())
        try expect(visible.map(\.id) == [dueToday.id, future.id, noDeadline.id], "应过滤昨天截止项并保留今天、未来和无期限事项")
    }

    private static func testGregorianBoundaries() throws {
        let calendar = utcCalendar()
        let values = [
            DueDate(date: try date(2024, 2, 29, calendar: calendar), calendar: calendar),
            DueDate(date: try date(2024, 3, 1, calendar: calendar), calendar: calendar),
            DueDate(date: try date(2025, 12, 31, calendar: calendar), calendar: calendar),
            DueDate(date: try date(2026, 1, 1, calendar: calendar), calendar: calendar)
        ]
        try expect(values[0] < values[1], "闰日应早于三月一日")
        try expect(values[1] < values[2], "跨年排序应按年月日递增")
        try expect(values[2] < values[3], "年末应早于次年元旦")
        try expect(values[0].date(calendar: calendar) == (try date(2024, 2, 29, calendar: calendar)), "2024-02-29 应可构造")
    }

    private static func testDaylightSavingDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let cases: [(Int, Int, TimeInterval)] = [(3, 9, 23 * 60 * 60), (11, 2, 25 * 60 * 60)]
        for (month, day, expectedDuration) in cases {
            let start = try date(2025, month, day, calendar: calendar)
            let interval = calendar.dateInterval(of: .day, for: start)!
            try expect(interval.duration == expectedDuration, "2025-\(month)-\(day) 应有 \(expectedDuration / 3600) 小时")

            let due = DueDate(date: start, calendar: calendar)
            let finalSecond = interval.end.addingTimeInterval(-1)
            try expect(!due.isExpired(at: finalSecond, calendar: calendar), "夏令时切换日结束前不应过期")
            try expect(due.isExpired(at: interval.end, calendar: calendar), "夏令时切换日后的零点应过期")
        }
    }

    private static func testTimeZoneChangePreservesCivilDate() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let source = try date(2025, 12, 31, 23, 30, calendar: losAngeles)
        let due = DueDate(date: source, calendar: losAngeles)
        let reconstructedInTokyo = due.date(calendar: tokyo)

        try expect(DueDate(date: reconstructedInTokyo, calendar: tokyo) == due, "切换时区后年月日应保持一致")
        let components = tokyo.dateComponents([.year, .month, .day], from: reconstructedInTokyo)
        try expect(components.year == 2025 && components.month == 12 && components.day == 31, "东京日历应仍显示存储的2025-12-31")
    }

    private static func testReminderSorting() throws {
        let calendar = Calendar.current
        let today = DueDate(date: Date(), calendar: calendar).date(calendar: calendar)
        let earlierDue = DueDate(date: calendar.date(byAdding: .day, value: 1, to: today)!, calendar: calendar)
        let laterDue = DueDate(date: calendar.date(byAdding: .day, value: 2, to: today)!, calendar: calendar)
        let creationEarly = try date(2024, 1, 1, calendar: calendar)
        let creationLate = try date(2024, 1, 2, calendar: calendar)
        let sameTimeFirstID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let sameTimeSecondID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let first = reminder("先创建", id: UUID(), due: earlierDue, createdAt: creationEarly)
        let second = reminder("后创建", id: UUID(), due: earlierDue, createdAt: creationLate)
        let third = reminder("较晚截止", id: UUID(), due: laterDue, createdAt: creationEarly)
        let noDeadlineFirst = reminder("无期限ID小", id: sameTimeFirstID, createdAt: creationEarly)
        let noDeadlineSecond = reminder("无期限ID大", id: sameTimeSecondID, createdAt: creationEarly)
        let sorted = Reminder.visible(from: [noDeadlineSecond, third, second, noDeadlineFirst, first], at: Date())

        try expect(sorted.map(\.id) == [first.id, second.id, third.id, sameTimeFirstID, sameTimeSecondID], "排序应按截止日、创建时间、ID排列")
    }

    private static func testCodableRoundTrip() throws {
        let calendar = utcCalendar()
        let item = reminder(
            "跨日任务",
            id: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
            due: DueDate(date: try date(2024, 2, 29, calendar: calendar), calendar: calendar),
            createdAt: try date(2024, 2, 1, 12, 34, 56, calendar: calendar),
            notes: "保留备注"
        )
        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(Reminder.self, from: encoded)
        try expect(decoded == item, "JSON往返后的事项字段应完全一致")
        try expect(String(data: encoded, encoding: .utf8)?.contains("\"year\":2024") == true, "截止日期JSON应保存公历字段")
    }

    private static func testRepositorySaveAndLoad() throws {
        let defaults = MemoryUserDefaults()
        let repository = ReminderRepository(defaults: defaults)
        let item = reminder("保存项目", id: UUID(), notes: "内存持久化")

        try repository.save([item])
        try expect(try repository.load() == [item], "保存后应读取到原事项")
    }

    private static func testRepositoryCreateEditDelete() throws {
        let defaults = MemoryUserDefaults()
        let repository = ReminderRepository(defaults: defaults)
        let id = UUID()
        let original = reminder("新建", id: id, notes: "初始备注")
        try repository.save([original])
        try expect(try repository.load() == [original], "新增后应读取到事项")

        let edited = reminder("编辑后", id: id, notes: "修改备注")
        try repository.save([edited])
        try expect(try repository.load() == [edited], "编辑后应保留ID并读取新字段")

        try repository.save([])
        try expect(try repository.load().isEmpty, "删除后应读取到空列表")
    }

    private static func testSyncMigrationPreservesLegacyData() throws {
        try withTemporaryDirectory { directory in
            let defaults = MemoryUserDefaults()
            let createdAt = try date(2024, 8, 9, 10, 11, 12, calendar: utcCalendar())
            let original = reminder(
                "legacy标题",
                id: UUID(uuidString: "10234567-89AB-CDEF-0123-456789ABCDEF")!,
                createdAt: createdAt,
                notes: "legacy备注"
            )
            let legacyBytes = try JSONEncoder().encode([original])
            defaults.set(legacyBytes, forKey: "reminders.json")
            let snapshotURL = directory.appendingPathComponent("widget-reminders.json")
            let repository = ReminderRepository(defaults: defaults, snapshotURL: snapshotURL)

            let state = try repository.loadSyncState()
            try expect(defaults.data(forKey: "reminders.json") == legacyBytes, "首次迁移不能改写legacy原字节")
            try expect(try repository.load() == [original], "迁移后load应返回原事项")
            try expect(state.entries.count == 1, "每个legacy事项应有一条版本记录")
            try expect(state.entries[0].record.id == original.id, "迁移应保留事项ID")
            try expect(state.entries[0].record.reminder == original, "迁移应保留全部事项字段")
            try expect(state.entries[0].record.modifiedAt == createdAt, "迁移版本时间应沿用createdAt")
            try expect(state.entries[0].needsUpload, "迁移记录应等待上传")
            try expect(defaults.data(forKey: "reminders.sync.v1") != nil, "迁移应保存独立同步文档")
            try expect(try ReminderRepository(snapshotURL: snapshotURL).load() == [original], "迁移快照应保持legacy事项")
        }
    }

    private static func testUnchangedReminderKeepsVersion() throws {
        let defaults = MemoryUserDefaults()
        let repository = ReminderRepository(defaults: defaults)
        let item = reminder("不变事项", id: UUID())
        let firstSave = try date(2025, 1, 2, calendar: utcCalendar())
        try repository.save([item], at: firstSave)
        let originalState = try repository.loadSyncState()

        _ = try repository.load()
        try repository.save([item], at: try date(2026, 1, 2, calendar: utcCalendar()))
        let finalState = try repository.loadSyncState()
        try expect(finalState == originalState, "load和未变save都不应改变事项版本或dirty状态")
    }

    private static func testOfflineDeleteAndLaterEditMerge() throws {
        let id = UUID(uuidString: "20234567-89AB-CDEF-0123-456789ABCDEF")!
        let baseTime = try date(2025, 1, 1, calendar: utcCalendar())
        let editTime = try date(2025, 1, 2, calendar: utcCalendar())
        let deleteTime = try date(2025, 1, 3, calendar: utcCalendar())
        let laterEditTime = try date(2025, 1, 4, calendar: utcCalendar())
        let original = reminder("原事项", id: id, createdAt: baseTime)
        let baseEntry = syncEntry(id: id, reminder: original, modifiedAt: baseTime, changeID: "00000000-0000-0000-0000-000000000010")
        let baseState = ReminderSyncState(entries: [baseEntry])

        let editDefaults = MemoryUserDefaults()
        let editRepository = ReminderRepository(defaults: editDefaults)
        try editRepository.saveSyncState(baseState)
        try editRepository.save([reminder("离线编辑", id: id, createdAt: baseTime)], at: editTime)

        let deleteDefaults = MemoryUserDefaults()
        let deleteRepository = ReminderRepository(defaults: deleteDefaults)
        try deleteRepository.saveSyncState(baseState)
        try deleteRepository.save([], at: deleteTime)
        try deleteRepository.mergeCloudRecords(try editRepository.loadSyncState().entries)
        let deletedState = try deleteRepository.loadSyncState()
        try expect(deletedState.entries[0].record.reminder == nil, "时间更晚的删除应压过离线编辑")
        try expect(deletedState.entries[0].record.modifiedAt == deleteTime, "删除墓碑应保留删除时间")
        try expect(deletedState.entries[0].needsUpload, "本地较新的删除仍应等待上传")

        let tombstone = deletedState.entries[0]
        let editAgainDefaults = MemoryUserDefaults()
        let editAgainRepository = ReminderRepository(defaults: editAgainDefaults)
        try editAgainRepository.saveSyncState(ReminderSyncState(entries: [tombstone]))
        let restored = reminder("删除后的离线编辑", id: id, createdAt: baseTime)
        try editAgainRepository.save([restored], at: laterEditTime)
        let restoredEntry = try editAgainRepository.loadSyncState().entries[0]

        let otherDefaults = MemoryUserDefaults()
        let otherRepository = ReminderRepository(defaults: otherDefaults)
        try otherRepository.saveSyncState(ReminderSyncState(entries: [tombstone]))
        try otherRepository.mergeCloudRecords([restoredEntry])
        let merged = try otherRepository.loadSyncState().entries[0]
        try expect(merged.record.reminder == restored, "比删除时间更晚的编辑应重新显示事项")
        try expect(!merged.needsUpload, "采用云端较新编辑后应清除dirty")
    }

    private static func testSyncTieBreakIsStable() throws {
        let id = UUID(uuidString: "30234567-89AB-CDEF-0123-456789ABCDEF")!
        let sameTime = try date(2025, 5, 6, calendar: utcCalendar())
        let lower = syncEntry(
            id: id,
            reminder: reminder("字典序较小", id: id),
            modifiedAt: sameTime,
            changeID: "00000000-0000-0000-0000-000000000001"
        )
        let higher = syncEntry(
            id: id,
            reminder: reminder("字典序较大", id: id),
            modifiedAt: sameTime,
            changeID: "00000000-0000-0000-0000-000000000002"
        )
        try expect(higher.record.isNewer(than: lower.record), "同时间应由字典序较大的changeID胜出")

        let firstRepository = ReminderRepository(defaults: MemoryUserDefaults())
        try firstRepository.mergeCloudRecords([lower])
        try firstRepository.mergeCloudRecords([higher])
        let first = try firstRepository.loadSyncState().entries[0].record

        let secondRepository = ReminderRepository(defaults: MemoryUserDefaults())
        try secondRepository.mergeCloudRecords([higher])
        try secondRepository.mergeCloudRecords([lower])
        let second = try secondRepository.loadSyncState().entries[0].record
        try expect(first == second, "不同到达顺序应收敛到同一版本")
        try expect(first.reminder?.title == "字典序较大", "changeID字典序较大的一方应胜出")
    }

    private static func testOldUploadAcknowledgementKeepsNewLocalEdit() throws {
        let defaults = MemoryUserDefaults()
        let repository = ReminderRepository(defaults: defaults)
        let id = UUID()
        let firstTime = try date(2025, 6, 1, calendar: utcCalendar())
        let secondTime = try date(2025, 6, 2, calendar: utcCalendar())
        try repository.save([reminder("首次修改", id: id)], at: firstTime)
        var acknowledgement = try repository.loadSyncState().entries[0]
        acknowledgement.cloudSystemFields = Data("server-tag".utf8)
        acknowledgement.needsUpload = false

        let newer = reminder("更新的本地修改", id: id)
        try repository.save([newer], at: secondTime)
        try repository.mergeCloudRecords([acknowledgement])
        let result = try repository.loadSyncState().entries[0]
        try expect(result.record.reminder == newer, "旧上传确认不能覆盖较新的本地内容")
        try expect(result.record.modifiedAt == secondTime, "本地较新版本时间应保留")
        try expect(result.needsUpload, "较新的本地版本仍应标记dirty")
        try expect(result.cloudSystemFields == Data("server-tag".utf8), "即使ACK版本较旧也要采用最新收到的server fields")
    }

    private static func testTombstonePersistsAndSnapshotOmitsDeleted() throws {
        try withTemporaryDirectory { directory in
            let defaults = MemoryUserDefaults()
            let snapshotURL = directory.appendingPathComponent("widget-reminders.json")
            let repository = ReminderRepository(defaults: defaults, snapshotURL: snapshotURL)
            let item = reminder("即将删除", id: UUID())
            try repository.save([item])
            try repository.save([])

            let snapshot = try JSONDecoder().decode([Reminder].self, from: Data(contentsOf: snapshotURL))
            try expect(snapshot.isEmpty, "小组件快照只应包含live事项")
            let restarted = ReminderRepository(defaults: defaults, snapshotURL: snapshotURL)
            let state = try restarted.loadSyncState()
            try expect(state.entries.count == 1 && state.entries[0].record.reminder == nil, "重启后删除墓碑应保留")
            try expect(try restarted.load().isEmpty, "墓碑事项不应重新出现在load结果")
            try expect(try restarted.loadSyncState().entries.count == 1, "load不能清理墓碑")
        }
    }

    private static func testInvalidSyncStateIsPreserved() throws {
        for invalidState in [
            Data("{broken sync document".utf8),
            Data(#"{"schemaVersion":99,"entries":[]}"#.utf8)
        ] {
            try withTemporaryDirectory { directory in
                let defaults = MemoryUserDefaults()
                let legacy = try JSONEncoder().encode([reminder("legacy", id: UUID())])
                let snapshotURL = directory.appendingPathComponent("widget-reminders.json")
                let snapshot = Data("existing snapshot".utf8)
                defaults.set(legacy, forKey: "reminders.json")
                defaults.set(invalidState, forKey: "reminders.sync.v1")
                try snapshot.write(to: snapshotURL)
                let repository = ReminderRepository(defaults: defaults, snapshotURL: snapshotURL)

                do {
                    _ = try repository.load()
                } catch {
                    try expect(defaults.data(forKey: "reminders.sync.v1") == invalidState, "坏同步文档字节必须保留")
                    try expect(defaults.data(forKey: "reminders.json") == legacy, "失败读取不能改legacy键")
                    try expect(try Data(contentsOf: snapshotURL) == snapshot, "失败读取不能覆盖已有快照")
                    return
                }
                throw TestFailure.expectation("损坏或未知schema同步文档应拒绝读取")
            }
        }
    }

    private static func testSyncSnapshotFailuresPreserveDefaults() throws {
        try withTemporaryDirectory { directory in
            let blocker = directory.appendingPathComponent("not-a-directory")
            try Data("blocker".utf8).write(to: blocker)
            let snapshotURL = blocker.appendingPathComponent("widget-reminders.json")

            let migrationDefaults = MemoryUserDefaults()
            let legacy = try JSONEncoder().encode([reminder("legacy", id: UUID())])
            migrationDefaults.set(legacy, forKey: "reminders.json")
            let migration = ReminderRepository(defaults: migrationDefaults, snapshotURL: snapshotURL)
            try expectSnapshotWriteFailure { _ = try migration.loadSyncState() }
            try expect(migrationDefaults.data(forKey: "reminders.sync.v1") == nil, "迁移快照失败不能创建同步键")
            try expect(migrationDefaults.data(forKey: "reminders.json") == legacy, "迁移快照失败不能改legacy键")

            let stateID = UUID()
            let validState = ReminderSyncState(entries: [syncEntry(
                id: stateID,
                reminder: reminder("原值", id: stateID),
                modifiedAt: Date(timeIntervalSince1970: 0),
                changeID: "40234567-89AB-CDEF-0123-456789ABCDEF"
            )])
            let originalSyncBytes = try JSONEncoder().encode(validState)
            let originalLegacyBytes = Data("legacy bytes".utf8)

            let saveDefaults = MemoryUserDefaults()
            saveDefaults.set(originalSyncBytes, forKey: "reminders.sync.v1")
            saveDefaults.set(originalLegacyBytes, forKey: "reminders.json")
            let saveRepository = ReminderRepository(defaults: saveDefaults, snapshotURL: snapshotURL)
            var changedState = validState
            changedState.cloudAccountID = "new-account"
            try expectSnapshotWriteFailure { try saveRepository.saveSyncState(changedState) }
            try expect(saveDefaults.data(forKey: "reminders.sync.v1") == originalSyncBytes, "saveSyncState快照失败不能改同步键")
            try expect(saveDefaults.data(forKey: "reminders.json") == originalLegacyBytes, "saveSyncState快照失败不能改legacy键")

            let mergeDefaults = MemoryUserDefaults()
            mergeDefaults.set(originalSyncBytes, forKey: "reminders.sync.v1")
            mergeDefaults.set(originalLegacyBytes, forKey: "reminders.json")
            let mergeRepository = ReminderRepository(defaults: mergeDefaults, snapshotURL: snapshotURL)
            let otherID = UUID()
            let cloudEntry = syncEntry(
                id: otherID,
                reminder: reminder("云端新增", id: otherID),
                modifiedAt: Date(),
                changeID: "50234567-89AB-CDEF-0123-456789ABCDEF"
            )
            try expectSnapshotWriteFailure { try mergeRepository.mergeCloudRecords([cloudEntry]) }
            try expect(mergeDefaults.data(forKey: "reminders.sync.v1") == originalSyncBytes, "merge快照失败不能改同步键")
            try expect(mergeDefaults.data(forKey: "reminders.json") == originalLegacyBytes, "merge快照失败不能改legacy键")
        }
    }

    private static func testInvalidSyncIdentifiersAreRejected() throws {
        let id = UUID()
        let first = syncEntry(id: id, reminder: reminder("重复1", id: id), modifiedAt: Date(), changeID: UUID())
        let duplicate = syncEntry(id: id, reminder: reminder("重复2", id: id), modifiedAt: Date(), changeID: UUID())
        let defaults = MemoryUserDefaults()
        let repository = ReminderRepository(defaults: defaults)
        do {
            try repository.saveSyncState(ReminderSyncState(entries: [first, duplicate]))
        } catch let error as ReminderRepositoryError {
            guard case .invalidStoredValue = error else {
                throw TestFailure.expectation("重复ID应返回invalidStoredValue，实际为\(error)")
            }
        }
        try expect(defaults.data(forKey: "reminders.sync.v1") == nil, "重复ID失败不能写同步键")

        let mismatched = syncEntry(
            id: id,
            reminder: reminder("ID不一致", id: UUID()),
            modifiedAt: Date(),
            changeID: UUID()
        )
        do {
            try repository.saveSyncState(ReminderSyncState(entries: [mismatched]))
        } catch let error as ReminderRepositoryError {
            guard case .invalidStoredValue = error else {
                throw TestFailure.expectation("不一致ID应返回invalidStoredValue，实际为\(error)")
            }
            try expect(defaults.data(forKey: "reminders.sync.v1") == nil, "ID不一致失败不能写同步键")
            return
        }
        throw TestFailure.expectation("不一致的记录ID和事项ID不应被保存")
    }

    private static func testConflictingPayloadForSameVersionIsRejected() throws {
        let id = UUID()
        let time = try date(2025, 7, 8, calendar: utcCalendar())
        let version = UUID(uuidString: "60234567-89AB-CDEF-0123-456789ABCDEF")!
        let local = syncEntry(
            id: id,
            reminder: reminder("本地payload", id: id),
            modifiedAt: time,
            changeID: version
        )
        let defaults = MemoryUserDefaults()
        let repository = ReminderRepository(defaults: defaults)
        try repository.saveSyncState(ReminderSyncState(entries: [local]))
        let originalSync = defaults.data(forKey: "reminders.sync.v1")
        let originalLegacy = defaults.data(forKey: "reminders.json")
        let conflicting = syncEntry(
            id: id,
            reminder: reminder("冲突payload", id: id),
            modifiedAt: time,
            changeID: version
        )

        do {
            try repository.mergeCloudRecords([conflicting])
        } catch let error as ReminderRepositoryError {
            guard case .invalidStoredValue = error else {
                throw TestFailure.expectation("同版本payload冲突应返回invalidStoredValue，实际为\(error)")
            }
            try expect(defaults.data(forKey: "reminders.sync.v1") == originalSync, "同版本冲突不能改同步文档")
            try expect(defaults.data(forKey: "reminders.json") == originalLegacy, "同版本冲突不能改legacy键")
            return
        }
        throw TestFailure.expectation("同版本键但不同payload应拒绝合并")
    }

    private static func testReadOnlyDefaultsDoesNotMigrate() throws {
        let defaults = MemoryUserDefaults()
        let item = reminder("只读legacy", id: UUID())
        let legacy = try JSONEncoder().encode([item])
        defaults.set(legacy, forKey: "reminders.json")
        let repository = ReminderRepository(defaults: defaults, readOnly: true)

        try expect(try repository.load() == [item], "只讀defaults模式应读取legacy事项")
        try expect(defaults.data(forKey: "reminders.sync.v1") == nil, "只读defaults load不能迁移同步文档")
        try expect(defaults.data(forKey: "reminders.json") == legacy, "只读defaults load不能改legacy原字节")
        try expectReadOnly { _ = try repository.loadSyncState() }
        try expectReadOnly { try repository.save([item]) }
        try expectReadOnly { try repository.saveSyncState(ReminderSyncState(entries: [])) }
        try expectReadOnly { try repository.mergeCloudRecords([]) }
        try expect(defaults.data(forKey: "reminders.sync.v1") == nil, "只读操作都不能创建同步文档")
    }

    private static func syncEntry(
        id: UUID,
        reminder: Reminder?,
        modifiedAt: Date,
        changeID: String,
        cloudSystemFields: Data? = nil,
        needsUpload: Bool = true
    ) -> ReminderSyncEntry {
        syncEntry(
            id: id,
            reminder: reminder,
            modifiedAt: modifiedAt,
            changeID: UUID(uuidString: changeID)!,
            cloudSystemFields: cloudSystemFields,
            needsUpload: needsUpload
        )
    }

    private static func syncEntry(
        id: UUID,
        reminder: Reminder?,
        modifiedAt: Date,
        changeID: UUID,
        cloudSystemFields: Data? = nil,
        needsUpload: Bool = true
    ) -> ReminderSyncEntry {
        ReminderSyncEntry(
            record: ReminderSyncRecord(id: id, reminder: reminder, modifiedAt: modifiedAt, changeID: changeID),
            cloudSystemFields: cloudSystemFields,
            needsUpload: needsUpload
        )
    }

    private static func expectSnapshotWriteFailure(_ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch let error as ReminderRepositoryError {
            guard case .snapshotWriteFailed = error else {
                throw TestFailure.expectation("预期快照写失败，实际为\(error)")
            }
            return
        }
        throw TestFailure.expectation("快照路径阻塞时操作应失败")
    }

    private static func expectReadOnly(_ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch let error as ReminderRepositoryError {
            guard case .readOnly = error else {
                throw TestFailure.expectation("只读操作应返回readOnly，实际为\(error)")
            }
            return
        }
        throw TestFailure.expectation("只读操作应失败")
    }

    private static func testCorruptedDataIsPreserved() throws {
        let defaults = MemoryUserDefaults()
        let repository = ReminderRepository(defaults: defaults)
        let key = "reminders.json"
        let corrupted = Data("{invalid json".utf8)
        defaults.set(corrupted, forKey: key)

        do {
            _ = try repository.load()
        } catch {
            try expect(defaults.data(forKey: key) == corrupted, "load报错后原损坏字节必须保留")
            return
        }
        throw TestFailure.expectation("损坏JSON应使load抛错")
    }

    private static func testSnapshotTracksHostChanges() throws {
        try withTemporaryDirectory { directory in
            let defaults = MemoryUserDefaults()
            let snapshotURL = directory.appendingPathComponent("widget-reminders.json")
            let host = ReminderRepository(defaults: defaults, snapshotURL: snapshotURL)
            let widget = ReminderRepository(snapshotURL: snapshotURL)
            let id = UUID()
            let original = reminder("新增", id: id, notes: "初始备注")

            try host.save([original])
            try expect(try widget.load() == [original], "主仓库保存后只读仓库应读到新增事项")

            let edited = reminder("编辑后", id: id, notes: "修改备注")
            try host.save([edited])
            try expect(try widget.load() == [edited], "主仓库编辑后只读仓库应读到新字段")

            try host.save([])
            try expect(try widget.load().isEmpty, "主仓库删除后只读仓库应读到空列表")
        }
    }

    private static func testLegacyLoadExportsSnapshot() throws {
        try withTemporaryDirectory { directory in
            let defaults = MemoryUserDefaults()
            let snapshotURL = directory.appendingPathComponent("widget-reminders.json")
            let item = reminder("旧数据", id: UUID(), notes: "legacy")
            let originalData = try JSONEncoder().encode([item])
            defaults.set(originalData, forKey: "reminders.json")
            let host = ReminderRepository(defaults: defaults, snapshotURL: snapshotURL)
            let widget = ReminderRepository(snapshotURL: snapshotURL)

            try expect(try host.load() == [item], "首次读取应返回原legacy事项")
            try expect(defaults.data(forKey: "reminders.json") == originalData, "导出快照不能改写legacy数据")
            try expect(try widget.load() == [item], "首次读取后只读仓库应读到导出的事项")
            try expect(FileManager.default.fileExists(atPath: snapshotURL.path), "首次读取应创建快照")
        }
    }

    private static func testSnapshotWriteFailurePreservesDefaults() throws {
        try withTemporaryDirectory { directory in
            let defaults = MemoryUserDefaults()
            let original = reminder("主数据", id: UUID())
            let originalData = try JSONEncoder().encode([original])
            defaults.set(originalData, forKey: "reminders.json")

            let blockingFile = directory.appendingPathComponent("not-a-directory")
            try Data("blocker".utf8).write(to: blockingFile)
            let snapshotURL = blockingFile.appendingPathComponent("widget-reminders.json")
            let host = ReminderRepository(defaults: defaults, snapshotURL: snapshotURL)
            let changed = reminder("不应写入", id: UUID())

            var rejectedSave = false
            do {
                try host.save([changed])
            } catch let error as ReminderRepositoryError {
                guard case .snapshotWriteFailed = error else {
                    throw TestFailure.expectation("快照写入失败应返回snapshotWriteFailed，实际为\(error)")
                }
                rejectedSave = true
            } catch {
                throw TestFailure.expectation("快照写入失败返回了非预期错误：\(error)")
            }

            try expect(rejectedSave, "快照写入失败时save必须抛错")
            try expect(defaults.data(forKey: "reminders.json") == originalData, "快照写失败后必须保留原defaults字节")
            try expect(defaults.data(forKey: "reminders.sync.v1") == nil, "快照写失败后不能创建同步文档")
        }
    }

    private static func testReadOnlySnapshotRejectsSave() throws {
        try withTemporaryDirectory { directory in
            let snapshotURL = directory.appendingPathComponent("widget-reminders.json")
            let original = reminder("快照", id: UUID())
            let originalData = try JSONEncoder().encode([original])
            try originalData.write(to: snapshotURL)
            let widget = ReminderRepository(snapshotURL: snapshotURL)

            var rejectedSave = false
            do {
                try widget.save([reminder("覆盖尝试", id: UUID())])
            } catch let error as ReminderRepositoryError {
                guard case .readOnly = error else {
                    throw TestFailure.expectation("只读仓库应返回readOnly，实际为\(error)")
                }
                rejectedSave = true
            } catch {
                throw TestFailure.expectation("只读仓库保存返回了非预期错误：\(error)")
            }

            try expect(rejectedSave, "只读仓库save必须抛错")
            try expect(try Data(contentsOf: snapshotURL) == originalData, "只读保存失败后快照文件字节必须不变")
        }
    }

    private static func testCorruptedSnapshotIsPreserved() throws {
        try withTemporaryDirectory { directory in
            let snapshotURL = directory.appendingPathComponent("widget-reminders.json")
            let corrupted = Data("{broken snapshot".utf8)
            try corrupted.write(to: snapshotURL)
            let widget = ReminderRepository(snapshotURL: snapshotURL)

            do {
                _ = try widget.load()
            } catch let error as ReminderRepositoryError {
                guard case .corruptedData = error else {
                    throw TestFailure.expectation("损坏快照应返回corruptedData，实际为\(error)")
                }
                try expect(try Data(contentsOf: snapshotURL) == corrupted, "读取损坏快照不能改写原字节")
                return
            } catch {
                throw TestFailure.expectation("读取损坏快照返回了非预期错误：\(error)")
            }
            throw TestFailure.expectation("损坏快照JSON应使只读load抛错")
        }
    }

    private static func testCorruptedLegacyDataPreservesSnapshot() throws {
        try withTemporaryDirectory { directory in
            let defaults = MemoryUserDefaults()
            let snapshotURL = directory.appendingPathComponent("widget-reminders.json")
            let item = reminder("已有快照", id: UUID())
            let snapshotData = try JSONEncoder().encode([item])
            let legacyData = Data("{broken legacy".utf8)
            try snapshotData.write(to: snapshotURL)
            defaults.set(legacyData, forKey: "reminders.json")
            let host = ReminderRepository(defaults: defaults, snapshotURL: snapshotURL)

            do {
                _ = try host.load()
            } catch {
                try expect(defaults.data(forKey: "reminders.json") == legacyData, "损坏legacy数据必须保留")
                try expect(try Data(contentsOf: snapshotURL) == snapshotData, "legacy解码失败不能覆盖已有快照")
                return
            }
            throw TestFailure.expectation("损坏legacy JSON应使host load抛错")
        }
    }

    private static func testMissingAndEmptySnapshotSemantics() throws {
        try withTemporaryDirectory { directory in
            let snapshotURL = directory.appendingPathComponent("widget-reminders.json")
            let widget = ReminderRepository(snapshotURL: snapshotURL)

            try expect(try widget.load().isEmpty, "缺失快照按只读API应返回空列表")
            try expect(!FileManager.default.fileExists(atPath: snapshotURL.path), "读取缺失快照不应创建文件")

            let host = ReminderRepository(defaults: MemoryUserDefaults(), snapshotURL: snapshotURL)
            try expect(try host.load().isEmpty, "主仓库无legacy记录时应返回空列表")
            try expect(FileManager.default.fileExists(atPath: snapshotURL.path), "主仓库首次load应导出显式空数组快照")
            try expect(try widget.load().isEmpty, "显式空数组快照按只读API也应返回空列表")
            try expect(try JSONDecoder().decode([Reminder].self, from: Data(contentsOf: snapshotURL)).isEmpty, "导出的文件内容应是可解码的空数组")
        }
    }

    private static func testInvalidCivilDateRejected() throws {
        let invalid = Data(#"{"id":"01234567-89AB-CDEF-0123-456789ABCDEF","title":"bad","notes":"","dueDate":{"year":2025,"month":2,"day":29},"createdAt":0}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Reminder.self, from: invalid)
        } catch {
            // 解码器已正确拒绝无效的公历日期。
            return
        }
        throw TestFailure.expectation("不存在的2025-02-29不应解码成功")
    }
}
