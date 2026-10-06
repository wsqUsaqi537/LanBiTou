import CloudKit
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

private func expectRejected(_ operation: () throws -> Void, _ message: String) throws {
    do {
        try operation()
    } catch {
        return
    }
    throw TestFailure.expectation(message)
}

/// Keeps disabled-sync repository checks in memory and avoids touching app-group defaults.
private final class MemoryUserDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }
}

@main
private struct CloudSyncTests {
    @MainActor
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("云记录编码解码保留事项字段", { try testActiveRecordRoundTrip() }),
            ("云记录墓碑编码解码保留版本", { try testTombstoneRoundTrip() }),
            ("异常云记录类型、zone、ID和payload会被拒绝", { try testMalformedRecordsAreRejected() }),
            ("system fields归档恢复保留record ID", { try testSystemFieldsRestoreRecordID() }),
            ("未配置iCloud时start和syncNow保持仓库原样", { try await testDisabledSyncDoesNotTouchRepository() })
        ]

        var failures = 0
        for (name, operation) in tests {
            do {
                try await operation()
                print("PASS \(name)")
            } catch {
                failures += 1
                fputs("FAIL \(name): \(error)\n", stderr)
            }
        }

        print("\(tests.count) tests, \(tests.count - failures) passed, \(failures) failed")
        if failures > 0 { exit(EXIT_FAILURE) }
    }

    private static func testActiveRecordRoundTrip() throws {
        let id = UUID(uuidString: "7F012345-6789-4ABC-8DEF-0123456789AB")!
        let modifiedAt = Date(timeIntervalSince1970: 1_733_456_789.125)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_123.5)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reminder = Reminder(
            id: id,
            title: "买咖啡豆",
            notes: "浅烘焙，带上优惠券",
            dueDate: DueDate(date: Date(timeIntervalSince1970: 1_748_966_400), calendar: calendar),
            createdAt: createdAt
        )
        let changeID = UUID(uuidString: "8F012345-6789-4ABC-8DEF-0123456789AB")!
        let entry = ReminderSyncEntry(
            record: ReminderSyncRecord(id: id, reminder: reminder, modifiedAt: modifiedAt, changeID: changeID),
            cloudSystemFields: nil,
            needsUpload: true
        )

        let cloudRecord = try ReminderCloudRecordCodec.encode(entry)
        try expect(cloudRecord.recordType == "ReminderV1", "record type应为ReminderV1")
        try expect(cloudRecord.recordID.recordName == id.uuidString, "record name应保留事项ID")
        try expect(cloudRecord.recordID.zoneID.zoneName == "LanBiTouReminders", "record应位于专用zone")
        try expect(cloudRecord["modifiedAt"] as? Date == modifiedAt, "modifiedAt应保留")
        try expect(cloudRecord["changeID"] as? String == changeID.uuidString, "changeID应保留")
        try expect((cloudRecord["isDeleted"] as? NSNumber)?.boolValue == false, "活动事项应标记为未删除")
        try expect(cloudRecord["payload"] as? Data != nil, "活动事项应写入payload")

        let decoded = try ReminderCloudRecordCodec.decode(cloudRecord)
        try expect(decoded.record == entry.record, "ID、标题、备注、截止日、创建时间和版本应往返一致")
        try expect(!decoded.needsUpload, "收到的云记录不应标记为待上传")
        try expect(decoded.cloudSystemFields != nil, "解码应归档record system fields")
    }

    private static func testTombstoneRoundTrip() throws {
        let id = UUID(uuidString: "9F012345-6789-4ABC-8DEF-0123456789AB")!
        let modifiedAt = Date(timeIntervalSince1970: 1_760_000_000.25)
        let changeID = UUID(uuidString: "AF012345-6789-4ABC-8DEF-0123456789AB")!
        let entry = ReminderSyncEntry(
            record: ReminderSyncRecord(id: id, reminder: nil, modifiedAt: modifiedAt, changeID: changeID),
            cloudSystemFields: nil,
            needsUpload: true
        )

        let cloudRecord = try ReminderCloudRecordCodec.encode(entry)
        try expect((cloudRecord["isDeleted"] as? NSNumber)?.boolValue == true, "墓碑应标记为已删除")
        try expect(cloudRecord["payload"] == nil, "墓碑不应携带事项payload")
        let decoded = try ReminderCloudRecordCodec.decode(cloudRecord)
        try expect(decoded.record == entry.record, "墓碑ID、时间和changeID应往返一致")
    }

    private static func testMalformedRecordsAreRejected() throws {
        let id = UUID(uuidString: "BF012345-6789-4ABC-8DEF-0123456789AB")!
        let reminder = Reminder(
            id: id,
            title: "合法payload",
            notes: "",
            dueDate: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let payload = try JSONEncoder().encode(reminder) as NSData
        let modifiedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let changeID = UUID(uuidString: "DF012345-6789-4ABC-8DEF-0123456789AB")!

        func record(
            type: String = "ReminderV1",
            name: String = id.uuidString,
            zone: String = "LanBiTouReminders",
            rawChangeID: String = changeID.uuidString
        ) -> CKRecord {
            let recordID = CKRecord.ID(recordName: name, zoneID: CKRecordZone.ID(zoneName: zone))
            let result = CKRecord(recordType: type, recordID: recordID)
            result["modifiedAt"] = modifiedAt as NSDate
            result["changeID"] = rawChangeID as NSString
            result["isDeleted"] = NSNumber(value: false)
            result["payload"] = payload
            return result
        }

        try expectRejected({ _ = try ReminderCloudRecordCodec.decode(record(type: "OtherRecord")) }, "未知record type应被拒绝")
        try expectRejected({ _ = try ReminderCloudRecordCodec.decode(record(zone: "OtherZone")) }, "其他zone的记录应被拒绝")
        try expectRejected({ _ = try ReminderCloudRecordCodec.decode(record(name: "not-a-uuid")) }, "无效record ID应被拒绝")
        try expectRejected({ _ = try ReminderCloudRecordCodec.decode(record(name: id.uuidString.lowercased())) }, "小写record ID应被拒绝")

        let lowerCaseChangeID = try ReminderCloudRecordCodec.decode(
            record(rawChangeID: changeID.uuidString.lowercased())
        )
        try expect(lowerCaseChangeID.record.changeID == changeID, "小写changeID应按UUID接受")

        let missingPayload = record()
        missingPayload["payload"] = nil
        try expectRejected({ _ = try ReminderCloudRecordCodec.decode(missingPayload) }, "活动记录缺少payload时应被拒绝")

        let invalidPayload = record()
        invalidPayload["payload"] = Data("not-json".utf8) as NSData
        try expectRejected({ _ = try ReminderCloudRecordCodec.decode(invalidPayload) }, "无法解码的payload应被拒绝")

        let mismatchedPayload = record()
        let otherReminder = Reminder(
            id: UUID(),
            title: "ID不一致",
            notes: "",
            dueDate: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        mismatchedPayload["payload"] = try JSONEncoder().encode(otherReminder) as NSData
        try expectRejected({ _ = try ReminderCloudRecordCodec.decode(mismatchedPayload) }, "payload事项ID不匹配时应被拒绝")

        for malformedDeletionValue in [0.5, 1.5, -0.5, 2.0, -1.0] {
            let malformedDeletion = record()
            malformedDeletion["isDeleted"] = NSNumber(value: malformedDeletionValue)
            try expectRejected(
                { _ = try ReminderCloudRecordCodec.decode(malformedDeletion) },
                "isDeleted=\(malformedDeletionValue)应被拒绝"
            )
        }
    }

    private static func testSystemFieldsRestoreRecordID() throws {
        let id = UUID(uuidString: "CF012345-6789-4ABC-8DEF-0123456789AB")!
        let reminder = Reminder(
            id: id,
            title: "system fields往返",
            notes: "",
            dueDate: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let entry = ReminderSyncEntry(
            record: ReminderSyncRecord(
                id: id,
                reminder: reminder,
                modifiedAt: Date(timeIntervalSince1970: 1_760_000_000),
                changeID: UUID()
            ),
            cloudSystemFields: nil,
            needsUpload: true
        )

        let original = try ReminderCloudRecordCodec.encode(entry)
        let decoded = try ReminderCloudRecordCodec.decode(original)
        guard let archivedFields = decoded.cloudSystemFields else {
            throw TestFailure.expectation("解码应保存system fields")
        }
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archivedFields)
        unarchiver.requiresSecureCoding = true
        let restored = CKRecord(coder: unarchiver)
        unarchiver.finishDecoding()
        try expect(restored?.recordID == original.recordID, "system fields归档恢复后的record ID应与原记录一致")

        let encodedAgain = try ReminderCloudRecordCodec.encode(decoded)
        try expect(encodedAgain.recordID == original.recordID, "使用归档system fields重建的record ID应与原记录一致")
    }

    @MainActor
    private static func testDisabledSyncDoesNotTouchRepository() async throws {
        let bundleInfo = Bundle.main.infoDictionary ?? [:]
        let enabled: Bool
        if let value = bundleInfo["ICloudSyncEnabled"] as? String {
            enabled = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YES"
        } else {
            enabled = bundleInfo["ICloudSyncEnabled"] as? Bool == true
        }
        try expect(!enabled, "此离线测试必须在未启用iCloud的测试Bundle中运行")

        let corruptedSyncData = Data("bad sync document".utf8)
        let corruptedLegacyData = Data("bad legacy document".utf8)
        let defaults = MemoryUserDefaults()
        defaults.set(corruptedSyncData, forKey: "reminders.sync.v1")
        defaults.set(corruptedLegacyData, forKey: "reminders.json")
        let sync = ReminderCloudSync(repository: ReminderRepository(defaults: defaults))

        await sync.start()
        await sync.syncNow()

        try expect(sync.statusText == "本地保存 · iCloud 待配置", "未配置时应显示待配置状态")
        try expect(defaults.data(forKey: "reminders.sync.v1") == corruptedSyncData, "禁用同步不能读取后覆盖损坏的同步文档")
        try expect(defaults.data(forKey: "reminders.json") == corruptedLegacyData, "禁用同步不能迁移或覆盖legacy数据")

        let emptyDefaults = MemoryUserDefaults()
        let emptySync = ReminderCloudSync(repository: ReminderRepository(defaults: emptyDefaults))
        await emptySync.start()
        await emptySync.syncNow()
        try expect(emptyDefaults.object(forKey: "reminders.sync.v1") == nil, "禁用同步不能创建同步文档")
        try expect(emptyDefaults.object(forKey: "reminders.json") == nil, "禁用同步不能创建legacy文档")
        try expect(emptySync.statusText == "本地保存 · iCloud 待配置", "禁用同步的syncNow应保持待配置状态")
    }
}
