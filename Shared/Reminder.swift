import Foundation

struct DueDate: Codable, Equatable, Comparable {
    let year: Int
    let month: Int
    let day: Int

    init(date: Date, calendar: Calendar = .current) {
        let gregorian = Self.gregorianCalendar(matching: calendar)
        let components = gregorian.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1
        month = components.month ?? 1
        day = components.day ?? 1
    }

    private init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    func date(calendar: Calendar = .current) -> Date {
        let gregorian = Self.gregorianCalendar(matching: calendar)
        let components = DateComponents(year: year, month: month, day: day)
        return gregorian.date(from: components) ?? .distantPast
    }

    func isExpired(at date: Date, calendar: Calendar = .current) -> Bool {
        DueDate(date: date, calendar: calendar) > self
    }

    static func < (lhs: DueDate, rhs: DueDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private static func gregorianCalendar(matching calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = calendar.locale
        return gregorian
    }

    private enum CodingKeys: String, CodingKey {
        case year
        case month
        case day
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let year = try container.decode(Int.self, forKey: .year)
        let month = try container.decode(Int.self, forKey: .month)
        let day = try container.decode(Int.self, forKey: .day)

        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(secondsFromGMT: 0) {
            calendar.timeZone = utc
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else {
            throw DecodingError.dataCorruptedError(
                forKey: .day,
                in: container,
                debugDescription: "截止日期必须是有效的公历年月日。"
            )
        }

        self.init(year: year, month: month, day: day)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(year, forKey: .year)
        try container.encode(month, forKey: .month)
        try container.encode(day, forKey: .day)
    }
}

struct DueTime: Codable, Equatable, Comparable {
    let hour: Int
    let minute: Int

    init(hour: Int, minute: Int) {
        precondition((0...23).contains(hour) && (0...59).contains(minute))
        self.hour = hour
        self.minute = minute
    }

    init(date: Date, calendar: Calendar = .current) {
        let gregorian = Self.gregorianCalendar(matching: calendar)
        let components = gregorian.dateComponents([.hour, .minute], from: date)
        hour = components.hour ?? 0
        minute = components.minute ?? 0
    }

    var timeLabel: String {
        String(format: "%02d:%02d", hour, minute)
    }

    static func < (lhs: DueTime, rhs: DueTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    private static func gregorianCalendar(matching calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = calendar.locale
        return gregorian
    }

    private enum CodingKeys: String, CodingKey {
        case hour
        case minute
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hour = try container.decode(Int.self, forKey: .hour)
        let minute = try container.decode(Int.self, forKey: .minute)
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw DecodingError.dataCorruptedError(
                forKey: hour < 0 || hour > 23 ? .hour : .minute,
                in: container,
                debugDescription: "截止时间必须是有效的小时和分钟。"
            )
        }

        self.hour = hour
        self.minute = minute
    }
}

struct Reminder: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var notes: String
    var dueDate: DueDate?
    var createdAt: Date
    var dueTime: DueTime? = nil
    var remindAt: Date? = nil

    func expirationDate(calendar: Calendar = .current) -> Date? {
        guard let dueDate else { return nil }

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = calendar.locale

        if let dueTime {
            var components = DateComponents()
            components.year = dueDate.year
            components.month = dueDate.month
            components.day = dueDate.day
            components.hour = dueTime.hour
            components.minute = dueTime.minute
            components.second = 0
            return gregorian.date(from: components)
        }

        let dayStart = dueDate.date(calendar: gregorian)
        return gregorian.date(byAdding: .day, value: 1, to: dayStart)
    }

    func deadlineDate(calendar: Calendar = .current) -> Date? {
        guard let dueDate else { return nil }
        if dueTime != nil {
            return expirationDate(calendar: calendar)
        }
        return dueDate.date(calendar: calendar)
    }

    static func visible(from reminders: [Reminder], at date: Date) -> [Reminder] {
        return reminders
            .filter { reminder in
                guard let expirationDate = reminder.expirationDate() else { return true }
                return date < expirationDate
            }
            .sorted { lhs, rhs in
                switch (lhs.expirationDate(), rhs.expirationDate()) {
                case let (left?, right?):
                    if left != right { return left < right }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }

                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}
