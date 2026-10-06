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
