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

struct Reminder: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var notes: String
    var dueDate: DueDate?
    var createdAt: Date

    static func visible(from reminders: [Reminder], at date: Date) -> [Reminder] {
        let currentDate = DueDate(date: date)
        return reminders
            .filter { reminder in
                guard let dueDate = reminder.dueDate else { return true }
                return dueDate >= currentDate
            }
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
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
