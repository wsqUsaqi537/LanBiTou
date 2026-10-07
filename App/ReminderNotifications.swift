import Combine
import Foundation
import UserNotifications

struct ReminderNotificationItem {
    let id: UUID
    let title: String
    let body: String
    let remindAt: Date?
}

@MainActor
final class ReminderNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var statusText = "尚未检查通知权限"
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var onOpenApp: (() -> Void)?

    private let notificationCenter = UNUserNotificationCenter.current()
    private var latestItems: [ReminderNotificationItem] = []
    private var currentNotificationIdentifiers: Set<String> = []
    private var reconcileRevision: UInt64 = 0
    private var reconcileTask: Task<Void, Never>?
    private var authorizationReadRevision: UInt64 = 0
    private var authorizationRequestRevision: UInt64 = 0

    private static let identifierPrefix = "lanbitou.reminder."
    private static let itemIDKey = "lanbitou.reminder.itemID"
    private static let fireDateKey = "lanbitou.reminder.fireDate"

    override init() {
        super.init()
        notificationCenter.delegate = self
    }

    func refreshAuthorization() async {
        authorizationReadRevision &+= 1
        let revision = authorizationReadRevision
        let settings = await notificationCenter.notificationSettings()
        guard revision == authorizationReadRevision else { return }

        apply(settings)
        reconcile(latestItems)
    }

    func requestAuthorization() async {
        authorizationRequestRevision &+= 1
        let revision = authorizationRequestRevision
        do {
            _ = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            guard revision == authorizationRequestRevision else { return }
            await refreshAuthorization()
        } catch {
            guard revision == authorizationRequestRevision else { return }
            statusText = "通知权限请求失败，提醒事项已保留：\(error.localizedDescription)"
        }
    }

    func reconcile(_ items: [ReminderNotificationItem]) {
        latestItems = items
        reconcileRevision &+= 1

        guard reconcileTask == nil else { return }
        reconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainReconciliations()
        }
    }

    private func drainReconciliations() async {
        while true {
            let revision = reconcileRevision
            let snapshot = latestItems
            await reconcileSnapshot(snapshot, revision: revision)

            guard revision != reconcileRevision else {
                reconcileTask = nil
                return
            }
        }
    }

    private func reconcileSnapshot(_ items: [ReminderNotificationItem], revision: UInt64) async {
        let itemsByIdentifier = Dictionary(
            items.map { (Self.identifier(for: $0.id), $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        authorizationReadRevision &+= 1
        let authorizationRevision = authorizationReadRevision
        let settings = await notificationCenter.notificationSettings()
        guard revision == reconcileRevision,
              authorizationRevision == authorizationReadRevision else { return }
        apply(settings)

        let pendingRequests = await notificationCenter.pendingNotificationRequests()
        guard revision == reconcileRevision,
              authorizationRevision == authorizationReadRevision else { return }

        let deliveredNotifications = await notificationCenter.deliveredNotifications()
        guard revision == reconcileRevision,
              authorizationRevision == authorizationReadRevision else { return }

        currentNotificationIdentifiers = Set(
            itemsByIdentifier.values
                .filter { $0.remindAt != nil }
                .map { Self.identifier(for: $0.id) }
        )

        let deliveredIdentifiersToRemove = deliveredNotifications.compactMap { notification -> String? in
            let identifier = notification.request.identifier
            guard identifier.hasPrefix(Self.identifierPrefix) else { return nil }
            guard currentNotificationIdentifiers.contains(identifier),
                  let item = itemsByIdentifier[identifier],
                  Self.matchesContent(notification.request.content, item: item) else {
                return identifier
            }
            return nil
        }
        notificationCenter.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiersToRemove)

        let canSchedule = Self.canSchedule(for: settings.authorizationStatus)
        var matchingPendingIdentifiers = Set<String>()
        var pendingIdentifiersToRemove: [String] = []
        let now = Date()

        for request in pendingRequests where request.identifier.hasPrefix(Self.identifierPrefix) {
            guard canSchedule,
                  let item = itemsByIdentifier[request.identifier],
                  let remindAt = item.remindAt,
                  remindAt > now else {
                pendingIdentifiersToRemove.append(request.identifier)
                continue
            }

            if Self.matchesPendingRequest(request, item: item) {
                matchingPendingIdentifiers.insert(request.identifier)
            } else {
                pendingIdentifiersToRemove.append(request.identifier)
            }
        }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: pendingIdentifiersToRemove)

        guard canSchedule else { return }

        for item in itemsByIdentifier.values {
            guard revision == reconcileRevision else { return }
            guard let remindAt = item.remindAt, remindAt > now else { continue }

            let identifier = Self.identifier(for: item.id)
            guard !matchingPendingIdentifiers.contains(identifier),
                  let request = Self.makeRequest(for: item) else { continue }

            do {
                try await notificationCenter.add(request)
            } catch {
                guard revision == reconcileRevision else { return }
                statusText = "通知安排失败，提醒事项已保留：\(error.localizedDescription)"
            }
        }
    }

    private func apply(_ settings: UNNotificationSettings) {
        authorizationStatus = settings.authorizationStatus
        statusText = Self.statusText(for: settings)
    }

    private static func statusText(for settings: UNNotificationSettings) -> String {
        switch settings.authorizationStatus {
        case .notDetermined:
            return "尚未请求通知权限"
        case .denied:
            return "通知权限已关闭，提醒事项已保留"
        case .authorized:
            let alertsEnabled = settings.alertSetting == .enabled && settings.alertStyle != .none
            let soundEnabled = settings.soundSetting == .enabled
            switch (alertsEnabled, soundEnabled) {
            case (true, true):
                return "通知权限已开启"
            case (false, true):
                return "通知已授权，但系统已关闭横幅或提醒样式"
            case (true, false):
                return "通知已授权，提醒显示可用，但系统已关闭声音"
            case (false, false):
                return "通知已授权，但系统已关闭横幅、提醒样式和声音"
            }
        case .provisional:
            return "通知已静默授权，提醒可能不会显示横幅或声音"
        @unknown default:
            return "通知权限状态未知，提醒事项已保留"
        }
    }

    private static func canSchedule(for status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    private static func identifier(for id: UUID) -> String {
        identifierPrefix + id.uuidString.lowercased()
    }

    private static func matchesContent(_ content: UNNotificationContent, item: ReminderNotificationItem) -> Bool {
        guard let remindAt = item.remindAt else { return false }
        let fireDate = content.userInfo[fireDateKey] as? NSNumber
        guard content.title == item.title,
              content.body == item.body,
              content.sound != nil,
              content.userInfo[itemIDKey] as? String == item.id.uuidString.lowercased(),
              fireDate?.doubleValue == remindAt.timeIntervalSince1970 else {
            return false
        }
        return true
    }

    static func matchesPendingRequest(_ request: UNNotificationRequest, item: ReminderNotificationItem) -> Bool {
        guard let remindAt = item.remindAt,
              matchesContent(request.content, item: item),
              let trigger = request.trigger as? UNCalendarNotificationTrigger,
              !trigger.repeats,
              let nextFireDate = trigger.nextTriggerDate() else {
            return false
        }

        let expectedFireDate = calendarFireDate(for: remindAt)
        return abs(nextFireDate.timeIntervalSince(expectedFireDate)) < 0.5
    }

    static func makeRequest(for item: ReminderNotificationItem) -> UNNotificationRequest? {
        guard let remindAt = item.remindAt else { return nil }
        let fireDate = calendarFireDate(for: remindAt)

        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.sound = .default
        content.userInfo = [
            itemIDKey: item.id.uuidString.lowercased(),
            fireDateKey: remindAt.timeIntervalSince1970
        ]

        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = timeZone
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        components.calendar = calendar
        components.timeZone = timeZone

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(
            identifier: identifier(for: item.id),
            content: content,
            trigger: trigger
        )
    }

    private static func calendarFireDate(for date: Date) -> Date {
        let roundedUpTimestamp = ceil(date.timeIntervalSince1970)
        return Date(timeIntervalSince1970: roundedUpTimestamp)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }

        Task { @MainActor [weak self] in
            self?.onOpenApp?()
        }
    }
}
