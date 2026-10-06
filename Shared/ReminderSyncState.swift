import Foundation

struct ReminderSyncRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var reminder: Reminder?
    var modifiedAt: Date
    var changeID: UUID

    func isNewer(than other: ReminderSyncRecord) -> Bool {
        if modifiedAt != other.modifiedAt {
            return modifiedAt > other.modifiedAt
        }
        return changeID.uuidString > other.changeID.uuidString
    }
}

struct ReminderSyncEntry: Codable, Equatable {
    var record: ReminderSyncRecord
    var cloudSystemFields: Data?
    var needsUpload: Bool
}

struct ReminderSyncState: Codable, Equatable {
    var schemaVersion: Int = 1
    var cloudScopeID: String? = nil
    var cloudAccountID: String?
    var engineState: Data?
    var entries: [ReminderSyncEntry]
}
