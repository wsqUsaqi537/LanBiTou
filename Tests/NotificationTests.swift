import Foundation
import UserNotifications

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

@MainActor
@main
private struct NotificationTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("提醒触发器保留秒级UTC时刻并只触发一次", testExactUTCTrigger),
            ("请求ID由事项UUID稳定生成且内容完整", testStableIdentifierAndContent),
            ("没有提醒时间时不创建请求", testMissingReminderDate),
            ("同一待处理请求匹配，标题或时间编辑后失配", testPendingRequestEdits),
            ("过去的提醒时间不匹配待处理请求", testPastTriggerDoesNotMatch)
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

    private static func testExactUTCTrigger() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = 2030
        components.month = 4
        components.day = 5
        components.hour = 6
        components.minute = 7
        components.second = 8
        components.nanosecond = 250_000_000
        let remindAt = try require(calendar.date(from: components), "应能构造测试提醒时间")
        let item = ReminderNotificationItem(id: UUID(), title: "报告", body: "准备材料", remindAt: remindAt)
        let request = try require(ReminderNotifications.makeRequest(for: item), "有提醒时间时应创建通知请求")
        let trigger = try require(request.trigger as? UNCalendarNotificationTrigger, "请求应使用公历触发器")
        let nextTriggerDate = try require(trigger.nextTriggerDate(), "系统应计算下一次触发时间")
        let expectedFireDate = Date(timeIntervalSince1970: ceil(remindAt.timeIntervalSince1970))

        try expect(!trigger.repeats, "提醒不应重复")
        try expect(abs(nextTriggerDate.timeIntervalSince(expectedFireDate)) < 0.001, "系统计算的触发时间应向上取整到下一秒")
        try expect(trigger.dateComponents.timeZone?.secondsFromGMT(for: expectedFireDate) == 0, "触发器应使用UTC时区")
        try expect(trigger.dateComponents.second == calendar.component(.second, from: expectedFireDate), "触发器应保留秒字段")
    }

    private static func testStableIdentifierAndContent() throws {
        let id = UUID(uuidString: "7F012345-6789-4ABC-8DEF-0123456789AB")!
        let item = ReminderNotificationItem(
            id: id,
            title: "缴电费",
            body: "在线缴费",
            remindAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        let first = try require(ReminderNotifications.makeRequest(for: item), "应创建首个请求")
        let second = try require(ReminderNotifications.makeRequest(for: item), "应创建重复请求")

        try expect(first.identifier == "lanbitou.reminder.\(id.uuidString.lowercased())", "请求ID应稳定地关联事项UUID")
        try expect(first.identifier == second.identifier, "相同事项应始终生成相同请求ID")
        try expect(first.content.title == item.title && first.content.body == item.body, "请求应包含最新标题和正文")
        try expect(first.content.sound != nil, "请求应包含默认提醒音")
    }

    private static func testMissingReminderDate() throws {
        let item = ReminderNotificationItem(id: UUID(), title: "无提醒", body: "", remindAt: nil)
        try expect(ReminderNotifications.makeRequest(for: item) == nil, "remindAt为nil时不应创建请求")
    }

    private static func testPendingRequestEdits() throws {
        let id = UUID()
        let remindAt = Date(timeIntervalSince1970: 1_900_000_000)
        let original = ReminderNotificationItem(id: id, title: "交报告", body: "", remindAt: remindAt)
        let request = try require(ReminderNotifications.makeRequest(for: original), "应创建待处理请求")
        let changedTitle = ReminderNotificationItem(id: id, title: "改过的标题", body: "", remindAt: remindAt)
        let changedTime = ReminderNotificationItem(id: id, title: original.title, body: "", remindAt: remindAt.addingTimeInterval(60))

        try expect(ReminderNotifications.matchesPendingRequest(request, item: original), "未编辑的待处理请求应匹配")
        try expect(!ReminderNotifications.matchesPendingRequest(request, item: changedTitle), "标题编辑后旧请求应失配")
        try expect(!ReminderNotifications.matchesPendingRequest(request, item: changedTime), "提醒时间编辑后旧请求应失配")
    }

    private static func testPastTriggerDoesNotMatch() throws {
        let item = ReminderNotificationItem(
            id: UUID(),
            title: "已过期",
            body: "",
            remindAt: Date(timeIntervalSince1970: 946_684_800)
        )
        let request = try require(ReminderNotifications.makeRequest(for: item), "可构造过去时间的请求以检查匹配行为")

        try expect(!ReminderNotifications.matchesPendingRequest(request, item: item), "过去的提醒时间不应作为有效待处理请求匹配")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure.expectation(message) }
        return value
    }
}
