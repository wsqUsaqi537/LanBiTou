import Combine
import AppKit
import SwiftUI
import UserNotifications
import WidgetKit

@main
struct LanBiTouApp: App {
    @StateObject private var store = ReminderStore()

    var body: some Scene {
        WindowGroup("烂笔头", id: "main") {
            ReminderHomeView(store: store, notifications: store.notifications)
                .frame(minWidth: 760, minHeight: 560)
                .preferredColorScheme(.light)
                .handlesExternalEvents(preferring: ["lanbitou://open"], allowing: ["lanbitou://open"])
        }
        .defaultSize(width: 920, height: 680)
        .handlesExternalEvents(matching: ["lanbitou://open"])
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
private final class ReminderStore: ObservableObject {
    @Published private(set) var reminders: [Reminder] = []
    @Published private(set) var isReady = false
    @Published private(set) var syncStatusText = "本地保存 · iCloud 待配置"
    @Published var errorMessage: String?

    private let repository: ReminderRepository
    private let cloudSync: ReminderCloudSync
    let notifications = ReminderNotifications()
    private var lastCheckedDate: DueDate?
    private var expirationTimer: Timer?
    private var lifecycleSubscriptions = Set<AnyCancellable>()

    init(repository: ReminderRepository = ReminderRepository()) {
        self.repository = repository
        cloudSync = ReminderCloudSync(repository: repository)
        cloudSync.onChange = { [weak self] in
            self?.refreshAndClean(at: Date(), force: true)
        }
        cloudSync.onStatusChange = { [weak self] status in
            self?.syncStatusText = status
        }
        notifications.onOpenApp = {
            if let url = URL(string: "lanbitou://open") {
                NSWorkspace.shared.open(url)
            }
        }
        NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshAndClean(at: Date(), force: true)
            }
            .store(in: &lifecycleSubscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshAndClean(at: Date(), force: true)
            }
            .store(in: &lifecycleSubscriptions)
        refreshAndClean(at: Date(), force: true)
        Task { await cloudSync.start() }
        Task { await notifications.refreshAuthorization() }
    }

    func refreshAndClean(at date: Date = Date(), force: Bool = false) {
        let today = DueDate(date: date)
        guard force || lastCheckedDate != today else { return }

        do {
            let loaded = try repository.load()
            isReady = true
            let cleaned = Reminder.visible(from: loaded, at: date)
            if cleaned.count != loaded.count {
                do {
                    try repository.save(cleaned, at: date)
                    reminders = cleaned
                } catch {
                    reminders = loaded
                    errorMessage = error.localizedDescription
                    lastCheckedDate = today
                    return
                }
            } else {
                reminders = loaded
            }

            errorMessage = nil
            lastCheckedDate = today
            cloudSync.localDataDidChange()
            updateNotificationsAndExpiration(at: date)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            isReady = false
            errorMessage = error.localizedDescription
        }
    }

    func add(title: String, notes: String, dueDate: DueDate?, dueTime: DueTime?, remindAt: Date?) throws {
        let now = Date()
        let current = Reminder.visible(from: reminders, at: now)
        var reminder = Reminder(
            id: UUID(),
            title: title,
            notes: notes,
            dueDate: dueDate,
            createdAt: now,
            dueTime: dueDate == nil ? nil : dueTime,
            remindAt: remindAt
        )
        reminder.title = try validatedTitle(title, reminder: reminder, previous: nil, at: now)
        try persist(current + [reminder], at: now)
        requestNotificationPermissionIfNeeded(for: reminder)
    }

    func update(id: UUID, title: String, notes: String, dueDate: DueDate?, dueTime: DueTime?, remindAt: Date?) throws {
        let now = Date()
        let current = Reminder.visible(from: reminders, at: now)
        guard let existing = current.first(where: { $0.id == id }) else {
            try persist(current, at: now)
            throw ReminderStoreError.expired
        }

        var updated = Reminder(
            id: existing.id,
            title: title,
            notes: notes,
            dueDate: dueDate,
            createdAt: existing.createdAt,
            dueTime: dueDate == nil ? nil : dueTime,
            remindAt: remindAt
        )
        updated.title = try validatedTitle(title, reminder: updated, previous: existing, at: now)
        try persist(current.map { $0.id == id ? updated : $0 }, at: now)
        requestNotificationPermissionIfNeeded(for: updated)
    }

    func delete(id: UUID) throws {
        let now = Date()
        let current = Reminder.visible(from: reminders, at: now)
        try persist(current.filter { $0.id != id }, at: now)
    }

    func syncWithCloud() {
        Task { await cloudSync.syncNow() }
    }

    private func validatedTitle(_ title: String, reminder: Reminder, previous: Reminder?, at date: Date) throws -> String {
        guard isReady else { throw ReminderStoreError.storageUnavailable }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw ReminderStoreError.blankTitle }
        if let deadline = reminder.expirationDate(), deadline <= date {
            throw ReminderStoreError.dueDateInPast
        }
        if let remindAt = reminder.remindAt {
            if remindAt <= date && remindAt != previous?.remindAt {
                throw ReminderStoreError.reminderInPast
            }
            if let deadline = reminder.expirationDate(), remindAt >= deadline {
                throw ReminderStoreError.reminderAfterDeadline
            }
        }
        return cleanTitle
    }

    private func persist(_ candidate: [Reminder], at date: Date) throws {
        guard isReady else { throw ReminderStoreError.storageUnavailable }
        let cleaned = Reminder.visible(from: candidate, at: date)
        do {
            try repository.save(cleaned, at: date)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }

        reminders = cleaned
        errorMessage = nil
        lastCheckedDate = DueDate(date: date)
        cloudSync.localDataDidChange()
        updateNotificationsAndExpiration(at: date)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func requestNotificationPermissionIfNeeded(for reminder: Reminder) {
        guard reminder.remindAt != nil else { return }
        Task {
            await notifications.refreshAuthorization()
            if notifications.authorizationStatus == .notDetermined {
                await notifications.requestAuthorization()
            }
        }
    }

    private func updateNotificationsAndExpiration(at date: Date) {
        notifications.reconcile(reminders.map { reminder in
            let body: String
            if let dueDate = reminder.dueDate {
                let day = dueDate.date().formatted(date: .abbreviated, time: .omitted)
                body = reminder.dueTime.map { "截止时间：\(day) \($0.timeLabel)" } ?? "截止日期：\(day)"
            } else {
                body = "你为这条事项设置了提醒。"
            }
            return ReminderNotificationItem(id: reminder.id, title: reminder.title, body: body, remindAt: reminder.remindAt)
        })

        expirationTimer?.invalidate()
        expirationTimer = nil
        guard let next = reminders.compactMap({ $0.expirationDate() }).filter({ $0 > date }).min() else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAndClean(at: Date(), force: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expirationTimer = timer
    }
}

private enum ReminderStoreError: LocalizedError {
    case storageUnavailable
    case blankTitle
    case dueDateInPast
    case expired
    case reminderInPast
    case reminderAfterDeadline

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "事项存储暂不可用，请检查配置后重新读取。"
        case .blankTitle:
            return "请填写事项标题。"
        case .dueDateInPast:
            return "截止时间必须晚于现在。"
        case .expired:
            return "这条事项已过期，已从列表中移除。"
        case .reminderInPast:
            return "提醒时间必须晚于现在。"
        case .reminderAfterDeadline:
            return "提醒时间必须早于截止时间。"
        }
    }
}

private enum ReminderFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case noDeadline

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部事项"
        case .today: return "今天截止"
        case .noDeadline: return "无期限"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .today: return "calendar"
        case .noDeadline: return "infinity"
        }
    }
}

private struct EditorTarget: Identifiable {
    let id: UUID
    let reminder: Reminder?

    init(reminder: Reminder?) {
        self.reminder = reminder
        id = reminder?.id ?? UUID()
    }
}

private struct ReminderHomeView: View {
    @ObservedObject var store: ReminderStore
    @ObservedObject var notifications: ReminderNotifications
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedFilter: ReminderFilter = .all
    @State private var editorTarget: EditorTarget?
    @State private var reminderPendingDeletion: Reminder?
    @State private var currentDate = Date()
    @State private var midnightTimer: Timer?
    @State private var isWindowVisible = false

    private var allVisibleReminders: [Reminder] {
        Reminder.visible(from: store.reminders, at: currentDate)
    }

    private var filteredReminders: [Reminder] {
        switch selectedFilter {
        case .all:
            return allVisibleReminders
        case .today:
            let today = DueDate(date: currentDate)
            return allVisibleReminders.filter { $0.dueDate == today }
        case .noDeadline:
            return allVisibleReminders.filter { $0.dueDate == nil }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 205, ideal: 230, max: 270)
        } detail: {
            mainContent
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            isWindowVisible = true
            refreshAndScheduleMidnight()
        }
        .onOpenURL { url in
            guard url.scheme?.caseInsensitiveCompare("lanbitou") == .orderedSame,
                  url.host?.caseInsensitiveCompare("open") == .orderedSame else { return }

            NSApp.activate(ignoringOtherApps: true)
            guard let window = NSApp.windows.first(where: { $0.title == "烂笔头" }) else { return }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        .onDisappear {
            isWindowVisible = false
            midnightTimer?.invalidate()
            midnightTimer = nil
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshAndScheduleMidnight()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            refreshAndScheduleMidnight()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            refreshAndScheduleMidnight()
        }
        .sheet(item: $editorTarget) { target in
            ReminderEditor(
                reminder: target.reminder,
                canMutate: store.isReady,
                onSave: { title, notes, dueDate, dueTime, remindAt in
                    if let reminder = target.reminder {
                        try store.update(id: reminder.id, title: title, notes: notes, dueDate: dueDate, dueTime: dueTime, remindAt: remindAt)
                    } else {
                        try store.add(title: title, notes: notes, dueDate: dueDate, dueTime: dueTime, remindAt: remindAt)
                    }
                },
                onDelete: { id in
                    try store.delete(id: id)
                }
            )
        }
        .confirmationDialog(
            "确定删除这条事项？",
            isPresented: Binding(
                get: { reminderPendingDeletion != nil },
                set: { if !$0 { reminderPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除事项", role: .destructive) {
                guard let reminder = reminderPendingDeletion else { return }
                do {
                    try store.delete(id: reminder.id)
                } catch {
                    store.errorMessage = error.localizedDescription
                }
                reminderPendingDeletion = nil
            }
            .disabled(!store.isReady)
            Button("取消", role: .cancel) { reminderPendingDeletion = nil }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private func refreshAndScheduleMidnight() {
        guard isWindowVisible else { return }
        let now = Date()
        currentDate = now
        store.refreshAndClean(at: now, force: true)
        store.syncWithCloud()
        Task { await notifications.refreshAuthorization() }
        scheduleNextMidnight(after: now)
    }

    private func scheduleNextMidnight(after date: Date) {
        midnightTimer?.invalidate()

        var midnight = DateComponents()
        midnight.hour = 0
        midnight.minute = 0
        midnight.second = 0
        guard let nextMidnight = Calendar.current.nextDate(
            after: date,
            matching: midnight,
            matchingPolicy: .nextTime
        ) else {
            midnightTimer = nil
            return
        }

        let timer = Timer(fire: nextMidnight, interval: 0, repeats: false) { _ in
            Task { @MainActor in
                refreshAndScheduleMidnight()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Image(systemName: "text.book.closed.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.terracotta)
                        .frame(width: 38, height: 38)
                        .background(Color.terracotta.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    Text("烂笔头")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink)
                }
                Text("把要紧的事，记下来。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedInk)
            }
            .padding(.horizontal, 5)

            VStack(spacing: 5) {
                ForEach(ReminderFilter.allCases) { filter in
                    filterButton(filter)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 8) {
                Label(notifications.statusText, systemImage: "bell")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedInk)
                    .lineLimit(3)
                    .help(notifications.statusText)
                if notifications.authorizationStatus == .notDetermined {
                    Button("开启通知") {
                        Task { await notifications.requestAuthorization() }
                    }
                    .controlSize(.small)
                } else {
                    Button("系统通知设置") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    Text("系统设置 → 通知 → 烂笔头")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedInk)
                }
            }
            .padding(.horizontal, 8)

            HStack(spacing: 8) {
                Circle()
                    .fill(store.isReady ? Color.green.opacity(0.75) : Color.orange)
                    .frame(width: 7, height: 7)
                Text(store.isReady ? store.syncStatusText : "存储暂不可用")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedInk)
                    .lineLimit(2)
                    .help(store.syncStatusText)
            }
            .padding(.horizontal, 8)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.sidebarBackground)
    }

    private func filterButton(_ filter: ReminderFilter) -> some View {
        let selected = selectedFilter == filter
        let count: Int = {
            switch filter {
            case .all:
                return allVisibleReminders.count
            case .today:
                return allVisibleReminders.filter { $0.dueDate == DueDate(date: currentDate) }.count
            case .noDeadline:
                return allVisibleReminders.filter { $0.dueDate == nil }.count
            }
        }()

        return Button {
            selectedFilter = filter
        } label: {
            HStack(spacing: 11) {
                Image(systemName: filter.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(filter.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(selected ? Color.terracotta : Color.mutedInk)
            }
            .foregroundStyle(selected ? Color.terracotta : Color.ink.opacity(0.76))
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                selected ? Color.terracotta.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 11)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedFilter.title)
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink)
                    Text(headerSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mutedInk)
                }
                Spacer()
                Button {
                    editorTarget = EditorTarget(reminder: nil)
                } label: {
                    Label("新建事项", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.terracotta)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!store.isReady)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 20)

            if let error = store.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if !store.isReady {
                        Button("重新读取") {
                            store.refreshAndClean(at: Date(), force: true)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 32)
                .padding(.bottom, 12)
            }

            if filteredReminders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 11) {
                        ForEach(filteredReminders) { reminder in
                            reminderRow(reminder)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 8)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pageBackground)
    }

    private var headerSubtitle: String {
        let count = filteredReminders.count
        return count == 0 ? "空出一点地方，等重要的事来到这里。" : "共 \(count) 条事项"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: selectedFilter == .today ? "sun.max" : "tray")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.terracotta.opacity(0.75))
                .frame(width: 72, height: 72)
                .background(Color.terracotta.opacity(0.08), in: Circle())
            Text(emptyTitle)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.ink)
            Text(emptySubtitle)
                .font(.system(size: 12))
                .foregroundStyle(Color.mutedInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var emptyTitle: String {
        switch selectedFilter {
        case .all: return store.isReady ? "还没有事项" : "暂时无法读取事项"
        case .today: return "今天没有截止事项"
        case .noDeadline: return "没有无期限事项"
        }
    }

    private var emptySubtitle: String {
        store.isReady ? "点击右上角的「新建事项」，记下接下来要做的事。" : "请检查共享存储配置，然后重新读取。"
    }

    private func reminderRow(_ reminder: Reminder) -> some View {
        Button {
            editorTarget = EditorTarget(reminder: reminder)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.terracotta.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(Color.terracotta.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 6) {
                    Text(reminder.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !reminder.notes.isEmpty {
                        Text(reminder.notes)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mutedInk)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    deadlineLabel(for: reminder)
                        .padding(.top, 2)
                    if let remindAt = reminder.remindAt {
                        Label(
                            "提醒 \(remindAt.formatted(date: .abbreviated, time: .shortened))",
                            systemImage: "bell"
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedInk)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.mutedInk.opacity(0.55))
                    .padding(.top, 5)
            }
            .padding(15)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 15))
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .stroke(Color.cardBorder, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("编辑事项", systemImage: "pencil") {
                editorTarget = EditorTarget(reminder: reminder)
            }
            Button("删除事项", systemImage: "trash", role: .destructive) {
                reminderPendingDeletion = reminder
            }
            .disabled(!store.isReady)
        }
        .disabled(!store.isReady)
    }

    @ViewBuilder
    private func deadlineLabel(for reminder: Reminder) -> some View {
        if let dueDate = reminder.dueDate {
            let isToday = dueDate == DueDate(date: currentDate)
            Label(
                deadlineText(dueDate: dueDate, dueTime: reminder.dueTime, isToday: isToday),
                systemImage: "calendar"
            )
            .font(.system(size: 10, weight: isToday ? .semibold : .regular))
            .foregroundStyle(isToday ? Color.terracotta : Color.mutedInk)
        } else {
            Label("无截止日期", systemImage: "infinity")
                .font(.system(size: 10))
                .foregroundStyle(Color.mutedInk)
        }
    }

    private func deadlineText(dueDate: DueDate, dueTime: DueTime?, isToday: Bool) -> String {
        let day = isToday ? "今天" : dueDate.date().formatted(date: .long, time: .omitted)
        if let dueTime { return "\(day) \(dueTime.timeLabel) 截止" }
        return isToday ? "今天截止（全天）" : "\(day) 截止（全天）"
    }
}

private struct ReminderEditor: View {
    @Environment(\.dismiss) private var dismiss

    let reminder: Reminder?
    let canMutate: Bool
    let onSave: (String, String, DueDate?, DueTime?, Date?) throws -> Void
    let onDelete: (UUID) throws -> Void

    @State private var title: String
    @State private var notes: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var hasDueTime: Bool
    @State private var hasReminder: Bool
    @State private var remindAt: Date
    @State private var showingDeleteConfirmation = false
    @State private var showingError = false
    @State private var errorMessage = ""

    init(
        reminder: Reminder?,
        canMutate: Bool,
        onSave: @escaping (String, String, DueDate?, DueTime?, Date?) throws -> Void,
        onDelete: @escaping (UUID) throws -> Void
    ) {
        self.reminder = reminder
        self.canMutate = canMutate
        self.onSave = onSave
        self.onDelete = onDelete
        _title = State(initialValue: reminder?.title ?? "")
        _notes = State(initialValue: reminder?.notes ?? "")
        _hasDueDate = State(initialValue: reminder?.dueDate != nil)
        let now = Date()
        _dueDate = State(initialValue: reminder?.deadlineDate() ?? Calendar.current.date(byAdding: .hour, value: 2, to: now) ?? now)
        _hasDueTime = State(initialValue: reminder?.dueDate == nil || reminder?.dueTime != nil)
        _hasReminder = State(initialValue: reminder?.remindAt != nil)
        _remindAt = State(initialValue: reminder?.remindAt ?? Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedDueDate: DueDate? {
        guard hasDueDate else { return nil }
        return DueDate(date: dueDate)
    }

    private var selectedDueTime: DueTime? {
        hasDueDate && hasDueTime ? DueTime(date: dueDate) : nil
    }

    private var selectedReminderDate: Date? {
        guard hasReminder else { return nil }
        return Calendar.current.dateInterval(of: .minute, for: remindAt)?.start ?? remindAt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(reminder == nil ? "新建事项" : "编辑事项")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink)
                    Text("写下标题，补充需要记住的细节。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mutedInk)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.mutedInk)
                        .frame(width: 28, height: 28)
                        .background(Color.black.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 17) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("标题")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.ink.opacity(0.8))
                    TextField("例如：给妈妈打电话", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.cardBorder, lineWidth: 1)
                        }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("备注")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.ink.opacity(0.8))
                    TextEditor(text: $notes)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 80, maxHeight: 110)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.cardBorder, lineWidth: 1)
                        }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Toggle("设置截止时间", isOn: $hasDueDate)
                        .font(.system(size: 13, weight: .medium))
                    if hasDueDate {
                        HStack {
                            Label(hasDueTime ? "截止时间" : "截止日期", systemImage: "calendar")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.mutedInk)
                            Spacer()
                            DatePicker(
                                "截止时间",
                                selection: $dueDate,
                                in: Calendar.current.startOfDay(for: Date())...,
                                displayedComponents: hasDueTime ? [.date, .hourAndMinute] : [.date]
                            )
                            .labelsHidden()
                            .datePickerStyle(.compact)
                        }
                        .padding(.leading, 2)
                        Toggle("选择具体时间", isOn: $hasDueTime)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                            .onChange(of: hasDueTime) { _, enabled in
                                if enabled && dueDate <= Date() {
                                    dueDate = Calendar.current.date(byAdding: .hour, value: 2, to: Date()) ?? Date()
                                }
                            }
                        Text(hasDueTime ? "到截止时间自动移除事项。" : "全天事项在次日零点自动移除。")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mutedInk)
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.cardBorder, lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Toggle("提醒我", isOn: $hasReminder)
                        .font(.system(size: 13, weight: .medium))
                    if hasReminder {
                        DatePicker("提醒时间", selection: $remindAt, displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.compact)
                            .font(.system(size: 12))
                        Text("提醒时间须晚于现在；有截止时间时，须早于截止时间。需允许烂笔头发送系统通知。")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mutedInk)
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.cardBorder, lineWidth: 1)
                }
            }
            .padding(.top, 25)

            Spacer(minLength: 20)

            HStack {
                if let reminder {
                    Button("删除事项", systemImage: "trash", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canMutate)
                    .confirmationDialog(
                        "确定删除这条事项？",
                        isPresented: $showingDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("删除事项", role: .destructive) {
                            do {
                                try onDelete(reminder.id)
                                dismiss()
                            } catch {
                                report(error)
                            }
                        }
                        .disabled(!canMutate)
                        Button("取消", role: .cancel) { }
                    } message: {
                        Text("删除后无法恢复。")
                    }
                }
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        try onSave(title, notes, selectedDueDate, selectedDueTime, selectedReminderDate)
                        dismiss()
                    } catch {
                        report(error)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.terracotta)
                .disabled(trimmedTitle.isEmpty || !canMutate)
            }
        }
        .padding(26)
        .frame(width: 540, height: 700)
        .background(Color.pageBackground)
        .alert("无法完成操作", isPresented: $showingError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        showingError = true
    }
}

private extension Color {
    static let pageBackground = Color(red: 0.982, green: 0.972, blue: 0.952)
    static let sidebarBackground = Color(red: 0.958, green: 0.942, blue: 0.913)
    static let cardBackground = Color(red: 1.0, green: 0.997, blue: 0.987)
    static let cardBorder = Color(red: 0.91, green: 0.88, blue: 0.83)
    static let terracotta = Color(red: 0.70, green: 0.31, blue: 0.22)
    static let ink = Color(red: 0.20, green: 0.19, blue: 0.17)
    static let mutedInk = Color(red: 0.48, green: 0.45, blue: 0.40)
}
