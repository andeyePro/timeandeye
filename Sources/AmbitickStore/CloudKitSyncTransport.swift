#if canImport(CloudKit)
import Foundation
import CloudKit
import AmbitickCore

/// CloudKit as the sync pipe: one custom zone in the user's PRIVATE database,
/// one record per session revision. Deliberately thin — ALL merge intelligence
/// lives in Core (JournalSyncer/SessionMerge); this file only maps
/// SessionRevision ⇄ CKRecord and cursors ⇄ CKServerChangeToken.
///
/// INERT until the app is built with a real signing identity + the iCloud
/// entitlement (the CLT ad-hoc build has neither); nothing constructs this
/// class until Settings' journal-sync toggle ships alongside that build.
public final class CloudKitSyncTransport: SyncTransport {
    public static let zoneName = "AmbitickJournal"
    static let recordType = "SessionRevision"

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private var zoneReady = false

    public init(container: CKContainer = .default()) {
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName,
                                      ownerName: CKCurrentUserDefaultName)
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)],
                                                 deleting: [])
        zoneReady = true
    }

    // MARK: - Mapping

    static func record(from rev: SessionRevision, zoneID: CKRecordZone.ID,
                       encoder: JSONEncoder) throws -> CKRecord {
        let id = CKRecord.ID(recordName: rev.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: id)
        // The session travels as its canonical JSON (same bytes as the SQLite
        // row) — new fields sync without CloudKit schema churn. Merge-relevant
        // meta is broken out queryably.
        record["json"] = try encoder.encode(rev.session) as CKRecordValue
        record["hlcMillis"] = rev.hlc.physicalMillis as CKRecordValue
        record["hlcCounter"] = Int64(rev.hlc.counter) as CKRecordValue
        record["hlcDevice"] = rev.hlc.deviceID as CKRecordValue
        record["origin"] = rev.origin.rawValue as CKRecordValue
        record["deleted"] = (rev.deleted ? 1 : 0) as CKRecordValue
        return record
    }

    static func revision(from record: CKRecord, decoder: JSONDecoder) -> SessionRevision? {
        guard record.recordType == recordType,
              let json = record["json"] as? Data,
              let session = try? decoder.decode(Session.self, from: json),
              let millis = record["hlcMillis"] as? Int64,
              let counter = record["hlcCounter"] as? Int64,
              let device = record["hlcDevice"] as? String else { return nil }
        return SessionRevision(
            session: session,
            hlc: HLC(physicalMillis: millis, counter: Int32(counter), deviceID: device),
            origin: (record["origin"] as? Int).flatMap(SliceOrigin.init(rawValue:)) ?? .auto,
            deleted: (record["deleted"] as? Int) == 1)
    }

    // MARK: - SyncTransport

    public func push(_ revisions: [SessionRevision]) async throws {
        try await ensureZone()
        let encoder = JSONEncoder()
        let records = try revisions.map {
            try Self.record(from: $0, zoneID: zoneID, encoder: encoder)
        }
        // .allKeys = last-writer-wins at the CK layer; genuine conflicts are
        // re-pulled and resolved by Core's merge, which is the real authority.
        _ = try await database.modifyRecords(saving: records, deleting: [],
                                             savePolicy: .allKeys)
    }

    public func pull(since token: SyncToken?) async throws -> (changes: [SessionRevision], token: SyncToken) {
        try await ensureZone()
        let startToken = token.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self,
                                                    from: $0.raw)
        }
        let decoder = JSONDecoder()
        var out: [SessionRevision] = []
        var cursor = startToken
        var more = true
        while more {
            let batch = try await database.recordZoneChanges(inZoneWith: zoneID,
                                                             since: cursor)
            out += batch.modificationResultsByID.values.compactMap {
                (try? $0.get()).flatMap { Self.revision(from: $0.record, decoder: decoder) }
            }
            // Deletions arrive as ids only; the row itself carries `deleted`
            // in our model, so a CK-level deletion only happens via tombstone
            // GC — treat it as no-op here (GC is a later, explicit pass).
            cursor = batch.changeToken
            more = batch.moreComing
        }
        let raw = (try? NSKeyedArchiver.archivedData(withRootObject: cursor as Any,
                                                     requiringSecureCoding: true)) ?? Data()
        return (out, SyncToken(raw: raw))
    }
}
#endif
