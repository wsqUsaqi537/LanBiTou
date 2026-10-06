import SwiftUI
import WidgetKit

private struct ReminderWidgetEntry: TimelineEntry {
    let date: Date
    let reminders: [Reminder]
    let hasError: Bool
    let isPlaceholder: Bool
}

private struct ReminderProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReminderWidgetEntry {
        ReminderWidgetEntry(date: .now, reminders: [], hasError: false, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (ReminderWidgetEntry) -> Void) {
        completion(loadEntry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReminderWidgetEntry>) -> Void) {
        let now = Date()
        let calendar = Calendar.current

        do {
            let reminders = try ReminderRepository().load()
            let today = calendar.startOfDay(for: now)
            var updateDates = Set<Date>()

            // Always ask WidgetKit to refresh on the next local day boundary.
            if let nextDay = calendar.date(byAdding: .day, value: 1, to: today) {
                updateDates.insert(nextDay)
            }

            // Precompute the moment each future-dated reminder becomes expired.
            for reminder in reminders {
                guard let dueDate = reminder.dueDate else { continue }
                let dueDay = calendar.startOfDay(for: dueDate.date(calendar: calendar))
                guard let expiration = calendar.date(byAdding: .day, value: 1, to: dueDay),
                      expiration > now else { continue }
                updateDates.insert(expiration)
            }

            let futureEntries = updateDates
                .filter { $0 > now }
                .sorted()
                .map { date in
                    ReminderWidgetEntry(
                        date: date,
                        reminders: Reminder.visible(from: reminders, at: date),
                        hasError: false,
                        isPlaceholder: false
                    )
                }
            let entries = [
                ReminderWidgetEntry(
                    date: now,
                    reminders: Reminder.visible(from: reminders, at: now),
                    hasError: false,
                    isPlaceholder: false
                )
            ] + futureEntries

            let policy: TimelineReloadPolicy
            if let nextDay = calendar.date(byAdding: .day, value: 1, to: today) {
                policy = .after(nextDay)
            } else {
                policy = .atEnd
            }
            completion(Timeline(entries: entries, policy: policy))
        } catch {
            let retryDate = calendar.date(byAdding: .minute, value: 30, to: now) ?? now
            completion(Timeline(
                entries: [ReminderWidgetEntry(date: now, reminders: [], hasError: true, isPlaceholder: false)],
                policy: .after(retryDate)
            ))
        }
    }

    private func loadEntry(at date: Date) -> ReminderWidgetEntry {
        do {
            let reminders = try ReminderRepository().load()
            return ReminderWidgetEntry(
                date: date,
                reminders: Reminder.visible(from: reminders, at: date),
                hasError: false,
                isPlaceholder: false
            )
        } catch {
            return ReminderWidgetEntry(date: date, reminders: [], hasError: true, isPlaceholder: false)
        }
    }
}

private enum WidgetPalette {
    static let paper = Color(red: 0.98, green: 0.96, blue: 0.91)
    static let ink = Color(red: 0.25, green: 0.23, blue: 0.20)
    static let secondaryInk = Color(red: 0.52, green: 0.48, blue: 0.42)
    static let pencil = Color(red: 0.78, green: 0.38, blue: 0.20)
    static let rule = Color(red: 0.86, green: 0.81, blue: 0.72)
}

private struct ReminderWidgetView: View {
    let entry: ReminderWidgetEntry

    @Environment(\.widgetFamily) private var family

    private var itemLimit: Int {
        switch family {
        case .systemSmall: 2
        case .systemMedium: 3
        default: 8
        }
    }

    private var visibleReminders: [Reminder] {
        Array(entry.reminders.prefix(itemLimit))
    }

    private var remainingCount: Int {
        max(0, entry.reminders.count - visibleReminders.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 12 : 8) {
            header

            if entry.isPlaceholder {
                placeholderState
            } else if entry.hasError {
                errorState
            } else if entry.reminders.isEmpty {
                emptyState
            } else {
                reminderList
            }

            Spacer(minLength: 0)
        }
        .padding(family == .systemSmall ? 14 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            ZStack {
                WidgetPalette.paper
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(WidgetPalette.rule.opacity(0.65), lineWidth: 1)
                    .padding(7)
            }
        }
        .widgetURL(URL(string: "lanbitou://open"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.tip.crop.circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(WidgetPalette.pencil)

            VStack(alignment: .leading, spacing: 1) {
                Text("烂笔头")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(WidgetPalette.ink)
                Text(headerSubtitle)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(WidgetPalette.secondaryInk)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var headerSubtitle: String {
        if entry.isPlaceholder { return "待办清单" }
        if entry.hasError { return "读取失败" }
        return "\(entry.reminders.count) 项待办"
    }

    private var reminderList: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 7) {
            ForEach(visibleReminders) { reminder in
                reminderRow(reminder)
            }

            if remainingCount > 0 {
                Text("还有 \(remainingCount) 条")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(WidgetPalette.pencil)
                    .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder
    private func reminderRow(_ reminder: Reminder) -> some View {
        if family == .systemSmall {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Circle()
                        .stroke(WidgetPalette.pencil.opacity(0.8), lineWidth: 1.3)
                        .frame(width: 11, height: 11)
                    Text(reminder.title)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(WidgetPalette.ink)
                        .lineLimit(1)
                }
                Text(deadlineLabel(for: reminder))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(WidgetPalette.secondaryInk)
                    .lineLimit(1)
                    .padding(.leading, 18)
            }
        } else {
            HStack(spacing: 7) {
                Circle()
                    .stroke(WidgetPalette.pencil.opacity(0.8), lineWidth: 1.3)
                    .frame(width: 11, height: 11)

                Text(reminder.title)
                    .font(.system(size: family == .systemLarge ? 13 : 12, weight: .medium, design: .rounded))
                    .foregroundColor(WidgetPalette.ink)
                    .lineLimit(1)

                Spacer(minLength: 2)

                Text(deadlineLabel(for: reminder))
                    .font(.system(size: family == .systemLarge ? 10 : 9, weight: .medium, design: .rounded))
                    .foregroundColor(WidgetPalette.secondaryInk)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func deadlineLabel(for reminder: Reminder) -> String {
        guard let dueDate = reminder.dueDate else { return "无期限" }
        let calendar = Calendar.current
        if calendar.isDate(dueDate.date(calendar: calendar), inSameDayAs: entry.date) {
            return "今天"
        }
        let dateLabel: String
        if dueDate.year == calendar.component(.year, from: entry.date) {
            dateLabel = "\(dueDate.month)月\(dueDate.day)日"
        } else {
            dateLabel = "\(dueDate.year)年\(dueDate.month)月\(dueDate.day)日"
        }
        return "截止 \(dateLabel)"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("暂无待办", systemImage: "checkmark.seal")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(WidgetPalette.ink)
            Text("新事项会显示在这里")
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundColor(WidgetPalette.secondaryInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var errorState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("无法读取清单", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(WidgetPalette.pencil)
            Text("打开烂笔头后重试")
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundColor(WidgetPalette.secondaryInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var placeholderState: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(0..<itemLimit, id: \.self) { _ in
                Capsule()
                    .fill(WidgetPalette.rule.opacity(0.75))
                    .frame(height: 7)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
    }
}

@main
struct LanBiTouWidget: Widget {
    let kind = "LanBiTouWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ReminderProvider()) { entry in
            ReminderWidgetView(entry: entry)
        }
        .configurationDisplayName("烂笔头")
        .description("在桌面查看你的待办事项")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
