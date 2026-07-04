import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct HistoryPoint {
    let ts: Int
    let chargePct: Double?
    let watts: Double?
    let systemWatts: Double?
    let healthPct: Double?
}

struct SampleRow {
    let ts: Int
    let chargePct: Double?
    let charging: Int?
    let watts: Double?
}

struct EventRow {
    let ts: Int
    let type: String
}

/// SQLite store sharing the schema (and the database file) of the original
/// Python collector, so existing history carries straight over. Every public
/// method serializes on an internal queue; call from any thread.
final class Store: @unchecked Sendable {
    static let defaultPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/macjuice/battery.db")
        .path

    private let queue = DispatchQueue(label: "com.macjuice.db", qos: .utility)
    private var db: OpaquePointer?

    init(path: String = Store.defaultPath) throws {
        try queue.sync {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard sqlite3_open(path, &db) == SQLITE_OK else {
                throw NSError(domain: "MacJuice", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "cannot open \(path)"])
            }
            exec("PRAGMA journal_mode=WAL")
            exec("PRAGMA synchronous=NORMAL")
            exec("PRAGMA busy_timeout=5000")
            exec("""
                CREATE TABLE IF NOT EXISTS samples (
                  ts INTEGER PRIMARY KEY,
                  source TEXT NOT NULL,
                  charge_pct REAL, current_mah REAL, max_mah REAL, design_mah REAL,
                  cycle_count INTEGER, max_capacity_reported_pct REAL, condition TEXT,
                  heavy_ts INTEGER, temp_c REAL, voltage_v REAL, amperage_ma REAL, watts REAL,
                  charging INTEGER, adapter_watts REAL, time_remaining_min INTEGER,
                  serial TEXT, model TEXT
                );
                CREATE TABLE IF NOT EXISTS events (
                  ts INTEGER NOT NULL, type TEXT NOT NULL, source TEXT NOT NULL, detail TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
                """)
            if !columns(of: "samples").contains("system_watts") {
                exec("ALTER TABLE samples ADD COLUMN system_watts REAL")
            }
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: - Writes

    func insert(_ s: BatterySnapshot, model: String?, source: String = "live") {
        queue.sync {
            let sql = """
                INSERT OR IGNORE INTO samples
                  (ts, source, charge_pct, current_mah, max_mah, design_mah, cycle_count,
                   max_capacity_reported_pct, condition, temp_c, voltage_v, amperage_ma,
                   watts, charging, adapter_watts, time_remaining_min, serial, model, system_watts)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """
            withStatement(sql) { st in
                bind(st, 1, s.ts)
                bind(st, 2, source)
                bind(st, 3, s.chargePct)
                bind(st, 4, s.currentMAh)
                bind(st, 5, s.maxMAh)
                bind(st, 6, s.designMAh)
                bind(st, 7, s.cycleCount)
                bind(st, 8, s.healthReportedPct)
                bind(st, 9, s.condition)
                bind(st, 10, s.tempC)
                bind(st, 11, s.voltageV)
                bind(st, 12, s.amperageMA)
                bind(st, 13, s.watts)
                bind(st, 14, s.onAC ? 1 : 0)
                bind(st, 15, s.adapterRatedWatts)
                bind(st, 16, s.timeRemainingMin)
                bind(st, 17, s.serial)
                bind(st, 18, model)
                bind(st, 19, s.systemWatts)
                sqlite3_step(st)
            }
        }
    }

    func insertEvent(ts: Int, type: String) {
        queue.sync {
            withStatement("INSERT INTO events (ts, type, source, detail) VALUES (?,?,?,NULL)") { st in
                bind(st, 1, ts)
                bind(st, 2, type)
                bind(st, 3, "live")
                sqlite3_step(st)
            }
        }
    }

    // MARK: - Reads

    func latestState() -> (chargePct: Double?, charging: Int?)? {
        queue.sync {
            var out: (Double?, Int?)?
            withStatement("SELECT charge_pct, charging FROM samples ORDER BY ts DESC LIMIT 1") { st in
                if sqlite3_step(st) == SQLITE_ROW {
                    out = (colDouble(st, 0), colInt(st, 1))
                }
            }
            return out
        }
    }

    /// Time-bucketed averages so charts stay ~a few hundred points no matter
    /// how many months of history accumulate.
    func history(since start: Int, bucketSeconds: Int) -> [HistoryPoint] {
        queue.sync {
            var out: [HistoryPoint] = []
            // The 0–100 clamp guards against historic backfill parser junk.
            let sql = """
                SELECT (ts/?1)*?1 AS t, AVG(charge_pct), AVG(watts), AVG(system_watts),
                       AVG(CASE WHEN design_mah > 0 THEN max_mah * 100.0 / design_mah END)
                FROM samples WHERE ts >= ?2 AND charge_pct BETWEEN 0 AND 100
                GROUP BY t ORDER BY t
                """
            withStatement(sql) { st in
                bind(st, 1, max(bucketSeconds, 1))
                bind(st, 2, start)
                while sqlite3_step(st) == SQLITE_ROW {
                    out.append(HistoryPoint(ts: colInt(st, 0) ?? 0,
                                            chargePct: colDouble(st, 1),
                                            watts: colDouble(st, 2),
                                            systemWatts: colDouble(st, 3),
                                            healthPct: colDouble(st, 4)))
                }
            }
            return out
        }
    }

    func events(since start: Int) -> [EventRow] {
        queue.sync {
            var out: [EventRow] = []
            withStatement("SELECT ts, type FROM events WHERE ts >= ? ORDER BY ts") { st in
                bind(st, 1, start)
                while sqlite3_step(st) == SQLITE_ROW {
                    if let t = colText(st, 1) {
                        out.append(EventRow(ts: colInt(st, 0) ?? 0, type: t))
                    }
                }
            }
            return out
        }
    }

    func rows(since start: Int) -> [SampleRow] {
        queue.sync {
            var out: [SampleRow] = []
            withStatement("""
                SELECT ts, charge_pct, charging, watts FROM samples
                WHERE ts >= ? AND (charge_pct IS NULL OR charge_pct BETWEEN 0 AND 100)
                ORDER BY ts
                """) { st in
                bind(st, 1, start)
                while sqlite3_step(st) == SQLITE_ROW {
                    out.append(SampleRow(ts: colInt(st, 0) ?? 0,
                                         chargePct: colDouble(st, 1),
                                         charging: colInt(st, 2),
                                         watts: colDouble(st, 3)))
                }
            }
            return out
        }
    }

    func lastEventTs(type: String) -> Int? {
        queue.sync {
            var out: Int?
            withStatement("SELECT ts FROM events WHERE type = ? ORDER BY ts DESC LIMIT 1") { st in
                bind(st, 1, type)
                if sqlite3_step(st) == SQLITE_ROW { out = colInt(st, 0) }
            }
            return out
        }
    }

    func firstSampleTs() -> Int? {
        queue.sync {
            var out: Int?
            withStatement("SELECT MIN(ts) FROM samples") { st in
                if sqlite3_step(st) == SQLITE_ROW { out = colInt(st, 0) }
            }
            return out
        }
    }

    /// Oldest and newest full-charge capacity readings, for the long-term
    /// capacity-decline trend.
    func capacityEndpoints() -> (first: (ts: Int, mAh: Double), last: (ts: Int, mAh: Double))? {
        queue.sync {
            func endpoint(_ order: String) -> (Int, Double)? {
                var out: (Int, Double)?
                withStatement("SELECT ts, max_mah FROM samples WHERE max_mah IS NOT NULL ORDER BY ts \(order) LIMIT 1") { st in
                    if sqlite3_step(st) == SQLITE_ROW, let ts = colInt(st, 0), let m = colDouble(st, 1) {
                        out = (ts, m)
                    }
                }
                return out
            }
            guard let f = endpoint("ASC"), let l = endpoint("DESC"), l.0 > f.0 else { return nil }
            return (f, l)
        }
    }

    /// Full samples table as CSV. Returns the row count written.
    func exportCSV(to url: URL) throws -> Int {
        try queue.sync {
            let cols = ["ts", "iso_local", "source", "charge_pct", "current_mah", "max_mah",
                        "design_mah", "cycle_count", "max_capacity_reported_pct", "condition",
                        "temp_c", "voltage_v", "amperage_ma", "watts", "system_watts",
                        "charging", "adapter_watts", "time_remaining_min"]
            var csv = cols.joined(separator: ",") + "\n"
            var count = 0
            let iso = DateFormatter()
            iso.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let sql = """
                SELECT ts, source, charge_pct, current_mah, max_mah, design_mah, cycle_count,
                       max_capacity_reported_pct, condition, temp_c, voltage_v, amperage_ma,
                       watts, system_watts, charging, adapter_watts, time_remaining_min
                FROM samples ORDER BY ts
                """
            withStatement(sql) { st in
                while sqlite3_step(st) == SQLITE_ROW {
                    let ts = colInt(st, 0) ?? 0
                    var fields: [String] = [
                        String(ts),
                        iso.string(from: Date(timeIntervalSince1970: TimeInterval(ts))),
                    ]
                    for i in 1..<17 {
                        switch sqlite3_column_type(st, Int32(i)) {
                        case SQLITE_NULL: fields.append("")
                        case SQLITE_TEXT: fields.append(colText(st, Int32(i)) ?? "")
                        default:
                            let v = sqlite3_column_double(st, Int32(i))
                            fields.append(v == v.rounded() ? String(Int(v)) : String(v))
                        }
                    }
                    csv += fields.joined(separator: ",") + "\n"
                    count += 1
                }
            }
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return count
        }
    }

    func meta(_ key: String) -> String? {
        queue.sync {
            var out: String?
            withStatement("SELECT value FROM meta WHERE key = ?") { st in
                bind(st, 1, key)
                if sqlite3_step(st) == SQLITE_ROW { out = colText(st, 0) }
            }
            return out
        }
    }

    func setMeta(_ key: String, _ value: String) {
        queue.sync {
            withStatement("INSERT INTO meta (key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value") { st in
                bind(st, 1, key)
                bind(st, 2, value)
                sqlite3_step(st)
            }
        }
    }

    func lastKnownModel() -> String? {
        queue.sync {
            var out: String?
            withStatement("SELECT model FROM samples WHERE model IS NOT NULL ORDER BY ts DESC LIMIT 1") { st in
                if sqlite3_step(st) == SQLITE_ROW { out = colText(st, 0) }
            }
            return out
        }
    }

    // MARK: - Plumbing (private; callers already hold the queue)

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func columns(of table: String) -> Set<String> {
        var out = Set<String>()
        withStatement("PRAGMA table_info(\(table))") { st in
            while sqlite3_step(st) == SQLITE_ROW {
                if let n = colText(st, 1) { out.insert(n) }
            }
        }
        return out
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer) -> Void) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
        body(st)
        sqlite3_finalize(st)
    }

    private func bind(_ st: OpaquePointer, _ i: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(st, i, v) } else { sqlite3_bind_null(st, i) }
    }
    private func bind(_ st: OpaquePointer, _ i: Int32, _ v: Int?) {
        if let v { sqlite3_bind_int64(st, i, Int64(v)) } else { sqlite3_bind_null(st, i) }
    }
    private func bind(_ st: OpaquePointer, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(st, i, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, i) }
    }

    private func colDouble(_ st: OpaquePointer, _ i: Int32) -> Double? {
        sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i)
    }
    private func colInt(_ st: OpaquePointer, _ i: Int32) -> Int? {
        sqlite3_column_type(st, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, i))
    }
    private func colText(_ st: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(st, i) else { return nil }
        return String(cString: c)
    }
}
