import CloudKit
import Foundation

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class ReminderCloudSync: CKSyncEngineDelegate {
    var onChange: (() -> Void)?
    var onStatusChange: ((String) -> Void)?

    private(set) var statusText = "本地保存 · iCloud 待配置"

    private let repository: ReminderRepository
    private var engine: CKSyncEngine?
    private var activeScopeID: String?
    private var activeAccountID: String?
    private var isStarting = false
    private var isSyncing = false
    private var isFetching = false
    private var fetchAttemptFailed = false
    private var lastFetchSucceeded = false
    private var fetchFailureText: String?
    private var sendAttemptFailed = false
    private var lastSendSucceeded = false
    private var sendFailureText: String?
    private var hasStorageFailure = false
    private var isAccountPaused = false
    private var deferredSerialization: CKSyncEngine.State.Serialization?

    private static let zoneName = "LanBiTouReminders"
    private static let batchLimit = 100

    init(repository: ReminderRepository) {
        self.repository = repository
    }

    func start() async {
        guard let configuration = Self.cloudConfiguration else {
            setStatus("本地保存 · iCloud 待配置")
            return
        }
        guard engine == nil, !isStarting else { return }

        isStarting = true
        defer { isStarting = false }

        do {
            var syncState = try repository.loadSyncState()
            if let savedScope = syncState.cloudScopeID {
                guard savedScope == configuration.scopeID else {
                    setStatus("本地保存 · iCloud 容器或环境已更改，原同步状态已保留")
                    return
                }
            } else {
                // An unscoped serialization cannot safely be used with a specific
                // container or environment. Keep logical records, but discard its
                // server change tags so later saves are conditional on this scope.
                syncState.cloudScopeID = configuration.scopeID
                syncState.engineState = nil
                syncState.entries = syncState.entries.map { entry in
                    var entry = entry
                    entry.cloudSystemFields = nil
                    return entry
                }
                try repository.saveSyncState(syncState)
            }

            let container = CKContainer(identifier: configuration.containerIdentifier)
            guard try await container.accountStatus() == .available else {
                setStatus("本地保存 · iCloud 账号暂不可用")
                return
            }

            let accountID = try await container.userRecordID().recordName
            // Account lookups suspend on MainActor. Reload before binding the account
            // or constructing the engine so edits made during the lookup are retained.
            syncState = try repository.loadSyncState()
            guard syncState.cloudScopeID == configuration.scopeID else {
                setStatus("本地保存 · iCloud 容器或环境已更改，原同步状态已保留")
                return
            }
            if let savedAccountID = syncState.cloudAccountID {
                guard savedAccountID == accountID else {
                    setStatus("本地保存 · 当前 iCloud 账号不同，原账号数据已保留")
                    return
                }
            } else {
                syncState.cloudAccountID = accountID
                try repository.saveSyncState(syncState)
            }

            let serialization: CKSyncEngine.State.Serialization?
            if let data = syncState.engineState {
                serialization = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            } else {
                serialization = nil
            }

            var engineConfiguration = CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: serialization,
                delegate: self
            )
            engineConfiguration.automaticallySync = true

            let engine = CKSyncEngine(engineConfiguration)
            self.engine = engine
            activeScopeID = configuration.scopeID
            activeAccountID = accountID
            isAccountPaused = false
            hasStorageFailure = false

            discardPhysicalDeleteRequests(in: engine)
            try enqueueZoneAndDirtyRecords(from: syncState, in: engine)
            await performSync()
        } catch {
            fail(error)
        }
    }

    func localDataDidChange() {
        guard Self.cloudConfiguration != nil else { return }
        guard let engine, !hasStorageFailure, !isAccountPaused else { return }

        do {
            let syncState = try repository.loadSyncState()
            try enqueueDirtyRecords(from: syncState, in: engine)
            updatePendingStatus(syncState)
        } catch {
            fail(error)
        }
    }

    func syncNow() async {
        guard Self.cloudConfiguration != nil else {
            setStatus("本地保存 · iCloud 待配置")
            return
        }
        if engine == nil {
            await start()
            return
        }
        guard !hasStorageFailure, !isAccountPaused, let engine else { return }
        await performSync(using: engine)
    }

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await process(event, syncEngine: syncEngine)
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await makeBatch(for: context, syncEngine: syncEngine)
    }

    nonisolated func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        await fetchOptions(for: context)
    }

    private func performSync(using requestedEngine: CKSyncEngine? = nil) async {
        guard !isSyncing, !hasStorageFailure, !isAccountPaused,
              let engine = requestedEngine ?? self.engine else { return }

        isSyncing = true
        defer { isSyncing = false }
        fetchAttemptFailed = false
        sendFailureText = nil
        sendAttemptFailed = false
        lastFetchSucceeded = false
        lastSendSucceeded = false
        do {
            try await engine.fetchChanges()
            guard !hasStorageFailure, !isAccountPaused else { return }
            if !fetchAttemptFailed {
                lastFetchSucceeded = true
                fetchFailureText = nil
            }
        } catch {
            markFetchFailure(error.localizedDescription)
            return
        }

        guard !hasStorageFailure, !isAccountPaused else { return }
        do {
            try await engine.sendChanges()
            guard !hasStorageFailure, !isAccountPaused else { return }
            if !sendAttemptFailed {
                lastSendSucceeded = true
                sendFailureText = nil
            }
        } catch {
            markSendFailure(error.localizedDescription)
            return
        }

        guard !hasStorageFailure, !isAccountPaused else { return }
        do {
            updatePendingStatus(try repository.loadSyncState())
        } catch {
            fail(error, engine: engine)
        }
    }

    private func fetchOptions(for context: CKSyncEngine.FetchChangesContext) -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        let zoneID = Self.zoneID
        options.scope = .zoneIDs([zoneID])
        options.prioritizedZoneIDs = [zoneID]
        return options
    }

    private func makeBatch(
        for context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !hasStorageFailure, !isAccountPaused else { return nil }

        do {
            let syncState = try repository.loadSyncState()
            let dirtyIDs = Set(syncState.entries.filter(\.needsUpload).map { $0.record.id })
            let staleChanges = syncEngine.state.pendingRecordZoneChanges.filter { change in
                switch change {
                case .saveRecord(let recordID) where recordID.zoneID == Self.zoneID:
                    guard let id = UUID(uuidString: recordID.recordName) else { return true }
                    return !dirtyIDs.contains(id)
                case .deleteRecord(let recordID) where recordID.zoneID == Self.zoneID:
                    return true
                default:
                    return false
                }
            }
            if !staleChanges.isEmpty {
                syncEngine.state.remove(pendingRecordZoneChanges: staleChanges)
            }

            let pending = syncEngine.state.pendingRecordZoneChanges.filter { change in
                guard context.options.scope.contains(change),
                      case .saveRecord(let recordID) = change else { return false }
                return recordID.zoneID == Self.zoneID
            }
            let limitedPending = Array(pending.prefix(Self.batchLimit))
            guard !limitedPending.isEmpty else { return nil }

            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: limitedPending) { [weak self] recordID in
                guard let self else { return nil }
                return await self.record(for: recordID)
            }
        } catch {
            fail(error, engine: syncEngine)
            return nil
        }
    }

    private func record(for recordID: CKRecord.ID) -> CKRecord? {
        guard !hasStorageFailure, !isAccountPaused,
              recordID.zoneID == Self.zoneID,
              let id = UUID(uuidString: recordID.recordName) else { return nil }

        do {
            try persistCurrentAccountGuard()
            let syncState = try repository.loadSyncState()
            guard let entry = syncState.entries.first(where: { $0.record.id == id }), entry.needsUpload else {
                return nil
            }
            return try ReminderCloudRecordCodec.encode(entry)
        } catch {
            fail(error, engine: engine)
            return nil
        }
    }

    private func process(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let update):
            guard !hasStorageFailure, !isAccountPaused else { return }
            if isFetching {
                deferredSerialization = update.stateSerialization
            } else if !fetchAttemptFailed {
                persist(update.stateSerialization, from: syncEngine)
            }

        case .accountChange(let accountChange):
            handleAccountChange(accountChange, engine: syncEngine)

        case .willFetchChanges:
            isFetching = true
            fetchAttemptFailed = false
            lastFetchSucceeded = false
            deferredSerialization = nil

        case .fetchedDatabaseChanges(let changes):
            handleDatabaseChanges(changes, engine: syncEngine)

        case .fetchedRecordZoneChanges(let changes):
            handleRecordZoneChanges(changes, engine: syncEngine)

        case .didFetchRecordZoneChanges(let fetched):
            if let error = fetched.error, isMissingZone(error) {
                recoverDeletedZone(in: syncEngine)
                markFetchFailure(error.localizedDescription)
            } else if let error = fetched.error {
                markFetchFailure(error.localizedDescription)
            }

        case .didFetchChanges:
            isFetching = false
            if !fetchAttemptFailed {
                lastFetchSucceeded = true
                fetchFailureText = nil
            }
            if let serialization = deferredSerialization,
               !fetchAttemptFailed,
               !hasStorageFailure,
               !isAccountPaused {
                persist(serialization, from: syncEngine)
            }
            deferredSerialization = nil
            updateStatusFromRepository()

        case .sentDatabaseChanges(let changes):
            handleSentDatabaseChanges(changes, engine: syncEngine)

        case .sentRecordZoneChanges(let changes):
            handleSentRecordChanges(changes, engine: syncEngine)

        case .didSendChanges:
            if !sendAttemptFailed {
                lastSendSucceeded = true
                sendFailureText = nil
            }
            updateStatusFromRepository()

        case .willSendChanges:
            sendAttemptFailed = false
            lastSendSucceeded = false
            sendFailureText = nil

        case .willFetchRecordZoneChanges:
            break

        @unknown default:
            fail(ReminderCloudSyncError.unsupportedCloudKitEvent, engine: syncEngine)
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange, engine: CKSyncEngine) {
        switch change.changeType {
        case .signOut:
            pauseForAccountChange("iCloud 已退出登录 · 本地数据已保留", engine: engine)
        case .switchAccounts:
            pauseForAccountChange("iCloud 账号已切换 · 原账号数据已保留", engine: engine)
        case .signIn(let currentUser):
            guard currentUser.recordName == activeAccountID,
                  scopeAndAccountMatch() else {
                pauseForAccountChange("当前 iCloud 账号不同 · 原账号数据已保留", engine: engine)
                return
            }
            guard !hasStorageFailure else { return }
            isAccountPaused = false
            do {
                let syncState = try repository.loadSyncState()
                try enqueueZoneAndDirtyRecords(from: syncState, in: engine)
                updatePendingStatus(syncState)
            } catch {
                fail(error, engine: engine)
            }
        @unknown default:
            pauseForAccountChange("iCloud 账号状态已变化 · 同步已暂停", engine: engine)
        }
    }

    private func handleDatabaseChanges(
        _ changes: CKSyncEngine.Event.FetchedDatabaseChanges,
        engine: CKSyncEngine
    ) {
        guard !hasStorageFailure, !isAccountPaused else { return }
        guard changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) else { return }
        recoverDeletedZone(in: engine)
        markFetchFailure("iCloud 同步区域已删除，正在重建")
    }

    private func handleRecordZoneChanges(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges,
        engine: CKSyncEngine
    ) {
        guard !hasStorageFailure, !isAccountPaused else { return }

        do {
            let entries = try changes.modifications
                .map(\.record)
                .filter { $0.recordID.zoneID == Self.zoneID }
                .map(ReminderCloudRecordCodec.decode)

            let physicalDeletions = changes.deletions.filter {
                $0.recordID.zoneID == Self.zoneID && $0.recordType == ReminderCloudRecordCodec.recordType
            }
            if !entries.isEmpty {
                try merge(entries, engine: engine)
            }
            if !physicalDeletions.isEmpty {
                try persistCurrentAccountGuard()
                var state = try repository.loadSyncState()
                let deletedIDs = Set(try physicalDeletions.map { deletion in
                    guard let id = ReminderCloudRecordCodec.id(forRecordName: deletion.recordID.recordName) else {
                        throw ReminderCloudRecordCodecError.invalidRecord
                    }
                    return id
                })
                state.entries = state.entries.map { entry in
                    guard deletedIDs.contains(entry.record.id) else { return entry }
                    var requeued = entry
                    requeued.cloudSystemFields = nil
                    requeued.needsUpload = true
                    return requeued
                }
                try repository.saveSyncState(state)
            }
            guard !entries.isEmpty || !physicalDeletions.isEmpty else { return }
            try reconcilePendingRecords(engine)
            setStatus("iCloud 正在接收更改")
        } catch {
            fail(error, engine: engine)
        }
    }

    private func handleSentDatabaseChanges(
        _ changes: CKSyncEngine.Event.SentDatabaseChanges,
        engine: CKSyncEngine
    ) {
        guard !hasStorageFailure, !isAccountPaused else { return }
        if let failed = changes.failedZoneSaves.first {
            if isMissingZone(failed.error) {
                recoverDeletedZone(in: engine)
            }
            markSendFailure(failed.error.localizedDescription)
        }
    }

    private func handleSentRecordChanges(
        _ changes: CKSyncEngine.Event.SentRecordZoneChanges,
        engine: CKSyncEngine
    ) {
        guard !hasStorageFailure, !isAccountPaused else { return }

        do {
            let savedEntries = try changes.savedRecords
                .filter { $0.recordID.zoneID == Self.zoneID }
                .map(ReminderCloudRecordCodec.decode)
            if !savedEntries.isEmpty {
                try merge(savedEntries, engine: engine)
                try reconcilePendingRecords(engine)
            }

            for failed in changes.failedRecordSaves {
                guard failed.record.recordID.zoneID == Self.zoneID else { continue }
                if isMissingZone(failed.error) {
                    recoverDeletedZone(in: engine)
                    markSendFailure(failed.error.localizedDescription)
                } else if failed.error.code == .serverRecordChanged,
                          let serverRecord = failed.error.serverRecord {
                    let serverEntry = try ReminderCloudRecordCodec.decode(serverRecord)
                    try merge([serverEntry], engine: engine)
                    try reconcilePendingRecords(engine)
                    markSendFailure("事项在其他设备上同时更改，已合并并等待重试")
                } else {
                    markSendFailure(failed.error.localizedDescription)
                }
            }
            for (recordID, error) in changes.failedRecordDeletes where recordID.zoneID == Self.zoneID {
                markSendFailure(error.localizedDescription)
            }
            if changes.deletedRecordIDs.contains(where: { $0.zoneID == Self.zoneID }) {
                markSendFailure("收到意外的物理删除，正在从本地同步记录恢复")
                requeueDeletedRecords(changes.deletedRecordIDs.filter { $0.zoneID == Self.zoneID }, engine: engine)
            }
            updateStatusFromRepository()
        } catch {
            fail(error, engine: engine)
        }
    }

    private func merge(_ entries: [ReminderSyncEntry], engine: CKSyncEngine) throws {
        try persistCurrentAccountGuard()
        let before = try repository.load()
        try repository.mergeCloudRecords(entries)
        let after = try repository.load()
        if before != after {
            onChange?()
        }
        try persistCurrentAccountGuard()
    }

    private func recoverDeletedZone(in engine: CKSyncEngine) {
        guard !hasStorageFailure, !isAccountPaused else { return }
        do {
            try persistCurrentAccountGuard()
            var syncState = try repository.loadSyncState()
            syncState.entries = syncState.entries.map { entry in
                var entry = entry
                entry.cloudSystemFields = nil
                entry.needsUpload = true
                return entry
            }
            try repository.saveSyncState(syncState)

            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            try enqueueDirtyRecords(from: syncState, in: engine)
            setStatus("iCloud 区域已重建 · 正在恢复本地事项")
        } catch {
            fail(error, engine: engine)
        }
    }

    private func requeueDeletedRecords(_ recordIDs: [CKRecord.ID], engine: CKSyncEngine) {
        guard !hasStorageFailure, !isAccountPaused else { return }
        do {
            try persistCurrentAccountGuard()
            let deletedIDs = Set(try recordIDs.map { recordID in
                guard let id = ReminderCloudRecordCodec.id(forRecordName: recordID.recordName) else {
                    throw ReminderCloudRecordCodecError.invalidRecord
                }
                return id
            })
            var state = try repository.loadSyncState()
            state.entries = state.entries.map { entry in
                guard deletedIDs.contains(entry.record.id) else { return entry }
                var entry = entry
                entry.cloudSystemFields = nil
                entry.needsUpload = true
                return entry
            }
            try repository.saveSyncState(state)
            try enqueueDirtyRecords(from: state, in: engine)
        } catch {
            fail(error, engine: engine)
        }
    }

    private func enqueueZoneAndDirtyRecords(from state: ReminderSyncState, in engine: CKSyncEngine) throws {
        try persistCurrentAccountGuard()
        let zoneIsPending = engine.state.pendingDatabaseChanges.contains { change in
            guard case .saveZone(let zone) = change else { return false }
            return zone.zoneID == Self.zoneID
        }
        if !zoneIsPending {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        try enqueueDirtyRecords(from: state, in: engine)
    }

    private func enqueueDirtyRecords(from state: ReminderSyncState, in engine: CKSyncEngine) throws {
        try persistCurrentAccountGuard()
        let entriesByID = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.record.id, $0) })
        let pending = engine.state.pendingRecordZoneChanges
        let obsolete = pending.filter { change in
            guard case .saveRecord(let recordID) = change,
                  recordID.zoneID == Self.zoneID,
                  let id = UUID(uuidString: recordID.recordName) else { return false }
            return entriesByID[id]?.needsUpload != true
        }
        if !obsolete.isEmpty {
            engine.state.remove(pendingRecordZoneChanges: obsolete)
        }

        let pendingIDs = Set(engine.state.pendingRecordZoneChanges.compactMap { change -> UUID? in
            guard case .saveRecord(let recordID) = change,
                  recordID.zoneID == Self.zoneID else { return nil }
            return UUID(uuidString: recordID.recordName)
        })
        let additions = state.entries.compactMap { entry -> CKSyncEngine.PendingRecordZoneChange? in
            guard entry.needsUpload, !pendingIDs.contains(entry.record.id) else { return nil }
            return .saveRecord(Self.recordID(for: entry.record.id))
        }
        if !additions.isEmpty {
            engine.state.add(pendingRecordZoneChanges: additions)
        }
    }

    private func reconcilePendingRecords(_ engine: CKSyncEngine) throws {
        let state = try repository.loadSyncState()
        try enqueueDirtyRecords(from: state, in: engine)
    }

    private func discardPhysicalDeleteRequests(in engine: CKSyncEngine) {
        let deletions = engine.state.pendingRecordZoneChanges.filter { change in
            guard case .deleteRecord(let recordID) = change else { return false }
            return recordID.zoneID == Self.zoneID
        }
        if !deletions.isEmpty {
            engine.state.remove(pendingRecordZoneChanges: deletions)
        }
    }

    private func persist(_ serialization: CKSyncEngine.State.Serialization, from engine: CKSyncEngine) {
        guard !hasStorageFailure, !isAccountPaused else { return }
        do {
            try persistCurrentAccountGuard()
            var state = try repository.loadSyncState()
            state.engineState = try JSONEncoder().encode(serialization)
            try repository.saveSyncState(state)
        } catch {
            fail(error, engine: engine)
        }
    }

    private func persistCurrentAccountGuard() throws {
        let state = try repository.loadSyncState()
        guard state.cloudScopeID == activeScopeID,
              state.cloudAccountID == activeAccountID else {
            throw ReminderCloudSyncError.accountOrScopeChanged
        }
    }

    private func scopeAndAccountMatch() -> Bool {
        guard let activeScopeID, let activeAccountID else { return false }
        do {
            let state = try repository.loadSyncState()
            return state.cloudScopeID == activeScopeID && state.cloudAccountID == activeAccountID
        } catch {
            fail(error, engine: engine)
            return false
        }
    }

    private func pauseForAccountChange(_ text: String, engine: CKSyncEngine) {
        isAccountPaused = true
        isFetching = false
        lastFetchSucceeded = false
        lastSendSucceeded = false
        deferredSerialization = nil
        setStatus(text)
        Task { await engine.cancelOperations() }
    }

    private func fail(_ error: Error, engine explicitEngine: CKSyncEngine? = nil) {
        hasStorageFailure = true
        isFetching = false
        deferredSerialization = nil
        setStatus("iCloud 同步已暂停 · \(error.localizedDescription)")
        if let engine = explicitEngine ?? self.engine {
            Task { await engine.cancelOperations() }
        }
    }

    private func updateStatusFromRepository() {
        guard !hasStorageFailure, !isAccountPaused else { return }
        do {
            updatePendingStatus(try repository.loadSyncState())
        } catch {
            fail(error, engine: engine)
        }
    }

    private func updatePendingStatus(_ state: ReminderSyncState) {
        guard !hasStorageFailure, !isAccountPaused else { return }
        if let fetchFailureText {
            setStatus("iCloud 拉取等待中 · \(fetchFailureText)")
            return
        }
        if let sendFailureText {
            setStatus("iCloud 保存等待中 · \(sendFailureText)")
            return
        }
        guard lastFetchSucceeded else {
            setStatus(isFetching ? "iCloud 正在拉取更改" : "本地保存 · 等待完成首次 iCloud 拉取")
            return
        }

        let pendingCount = state.entries.filter(\.needsUpload).count
        let hasPendingRecords = engine?.state.pendingRecordZoneChanges.contains { change in
            switch change {
            case .saveRecord(let recordID), .deleteRecord(let recordID):
                return recordID.zoneID == Self.zoneID
            @unknown default:
                return true
            }
        } ?? false
        let hasPendingZone = engine?.state.pendingDatabaseChanges.contains { change in
            guard case .saveZone(let zone) = change else { return false }
            return zone.zoneID == Self.zoneID
        } ?? false
        if pendingCount == 0 && !hasPendingRecords && !hasPendingZone && lastSendSucceeded {
            setStatus("本地保存 · iCloud 已同步")
        } else {
            setStatus("本地保存 · iCloud 等待同步（\(max(pendingCount, 1))）")
        }
    }

    private func markFetchFailure(_ message: String) {
        fetchAttemptFailed = true
        lastFetchSucceeded = false
        fetchFailureText = message
        setStatus("iCloud 拉取等待中 · \(message)")
    }

    private func markSendFailure(_ message: String) {
        sendAttemptFailed = true
        lastSendSucceeded = false
        sendFailureText = message
        setStatus("iCloud 保存等待中 · \(message)")
    }

    private func setStatus(_ text: String) {
        guard text != statusText else { return }
        statusText = text
        onStatusChange?(text)
    }

    private func isMissingZone(_ error: CKError) -> Bool {
        error.code == .zoneNotFound || error.code == .userDeletedZone
    }

    private static var cloudConfiguration: CloudConfiguration? {
        let info = Bundle.main.infoDictionary ?? [:]
        let enabled: Bool
        if let flag = info["ICloudSyncEnabled"] as? String {
            enabled = flag.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YES"
        } else {
            enabled = (info["ICloudSyncEnabled"] as? Bool) == true
        }
        guard enabled,
              let rawContainer = info["ICloudContainerIdentifier"] as? String else { return nil }

        let containerIdentifier = rawContainer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containerIdentifier.isEmpty, !containerIdentifier.contains("$(") else { return nil }

        guard let rawEnvironment = info["ICloudEnvironment"] as? String else { return nil }
        let environment = rawEnvironment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard environment == "Development" || environment == "Production" else { return nil }

        return CloudConfiguration(
            containerIdentifier: containerIdentifier,
            scopeID: "\(containerIdentifier)/\(environment)"
        )
    }

    private static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName)
    }

    private static func recordID(for id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    private struct CloudConfiguration {
        let containerIdentifier: String
        let scopeID: String
    }
}

enum ReminderCloudRecordCodec {
    static let recordType = "ReminderV1"

    private static let modifiedAtKey = "modifiedAt"
    private static let changeIDKey = "changeID"
    private static let isDeletedKey = "isDeleted"
    private static let payloadKey = "payload"

    static func encode(_ entry: ReminderSyncEntry) throws -> CKRecord {
        guard entry.record.modifiedAt.timeIntervalSince1970.isFinite else {
            throw ReminderCloudRecordCodecError.invalidRecord
        }
        guard entry.record.reminder?.id == nil || entry.record.reminder?.id == entry.record.id else {
            throw ReminderCloudRecordCodecError.invalidReminderID
        }

        let record: CKRecord
        if let data = entry.cloudSystemFields {
            guard let decoded = try decodeSystemFields(data),
                  decoded.recordType == recordType,
                  decoded.recordID == CKRecord.ID(recordName: entry.record.id.uuidString, zoneID: zoneID) else {
                throw ReminderCloudRecordCodecError.invalidSystemFields
            }
            record = decoded
        } else {
            record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: entry.record.id.uuidString, zoneID: zoneID))
        }

        record[modifiedAtKey] = entry.record.modifiedAt as NSDate
        record[changeIDKey] = entry.record.changeID.uuidString as NSString
        record[isDeletedKey] = NSNumber(value: entry.record.reminder == nil)
        if let reminder = entry.record.reminder {
            record[payloadKey] = try JSONEncoder().encode(reminder) as NSData
        } else {
            record[payloadKey] = nil
        }
        return record
    }

    static func decode(_ record: CKRecord) throws -> ReminderSyncEntry {
        guard record.recordType == recordType,
              record.recordID.zoneID == zoneID,
              let id = id(forRecordName: record.recordID.recordName),
              let modifiedAt = record[modifiedAtKey] as? Date,
              modifiedAt.timeIntervalSince1970.isFinite,
              let rawChangeID = record[changeIDKey] as? String,
              let changeID = canonicalUUID(rawChangeID),
              let deletedValue = record[isDeletedKey] as? NSNumber else {
            throw ReminderCloudRecordCodecError.invalidRecord
        }
        let deletionFlag = deletedValue.doubleValue
        guard deletionFlag.isFinite, deletionFlag == 0 || deletionFlag == 1 else {
            throw ReminderCloudRecordCodecError.invalidRecord
        }

        let reminder: Reminder?
        if deletionFlag == 1 {
            reminder = nil
        } else {
            guard let payload = record[payloadKey] as? Data else {
                throw ReminderCloudRecordCodecError.missingPayload
            }
            reminder = try JSONDecoder().decode(Reminder.self, from: payload)
            guard reminder?.id == id else {
                throw ReminderCloudRecordCodecError.invalidReminderID
            }
        }

        return ReminderSyncEntry(
            record: ReminderSyncRecord(id: id, reminder: reminder, modifiedAt: modifiedAt, changeID: changeID),
            cloudSystemFields: try encodeSystemFields(of: record),
            needsUpload: false
        )
    }

    static func id(forRecordName name: String) -> UUID? {
        guard let uuid = UUID(uuidString: name), uuid.uuidString == name else { return nil }
        return uuid
    }

    private static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "LanBiTouReminders")
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.caseInsensitiveCompare(value) == .orderedSame else { return nil }
        return uuid
    }

    private static func encodeSystemFields(of record: CKRecord) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func decodeSystemFields(_ data: Data) throws -> CKRecord? {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        let record = CKRecord(coder: unarchiver)
        unarchiver.finishDecoding()
        return record
    }
}

private enum ReminderCloudRecordCodecError: LocalizedError {
    case invalidSystemFields
    case invalidRecord
    case invalidReminderID
    case missingPayload

    var errorDescription: String? {
        switch self {
        case .invalidSystemFields:
            return "iCloud 事项的系统字段与记录 ID 不匹配。"
        case .invalidRecord:
            return "iCloud 事项记录缺少有效的类型、ID 或同步版本字段。"
        case .invalidReminderID:
            return "iCloud 事项记录 ID 与事项内容不匹配。"
        case .missingPayload:
            return "iCloud 活动事项缺少内容。"
        }
    }
}

private enum ReminderCloudSyncError: LocalizedError {
    case accountOrScopeChanged
    case unsupportedCloudKitEvent

    var errorDescription: String? {
        switch self {
        case .accountOrScopeChanged:
            return "iCloud 账号或容器环境已更改，已暂停同步以保护本地数据。"
        case .unsupportedCloudKitEvent:
            return "CloudKit 返回了无法处理的同步事件，已暂停同步以保护本地数据。"
        }
    }
}
