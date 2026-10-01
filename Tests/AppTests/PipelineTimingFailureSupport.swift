import Fluent
import Foundation
import SQLKit
import Testing

/// Fail only one fixture's timing writes, leaving delivery tables and other suites usable.
func withPipelineTimingWriteFailure(
    table: String, operation: String, seriesID: UUID, on db: any Database,
    test: () async throws -> Void
) async throws {
    let sql = try #require(db as? any SQLDatabase)
    let name = "timing_failure_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    try await sql.raw("""
        CREATE FUNCTION \(unsafeRaw: name)() RETURNS trigger LANGUAGE plpgsql AS
        $$ BEGIN RAISE EXCEPTION 'injected pipeline timing failure'; END $$
        """).run()
    try await sql.raw("""
        CREATE TRIGGER \(unsafeRaw: name) BEFORE \(unsafeRaw: operation) ON \(unsafeRaw: table)
        FOR EACH ROW WHEN (NEW.series_id = '\(unsafeRaw: seriesID.uuidString)'::uuid)
        EXECUTE FUNCTION \(unsafeRaw: name)()
        """).run()
    do {
        try await test()
    } catch {
        try await sql.raw("DROP TRIGGER \(unsafeRaw: name) ON \(unsafeRaw: table)").run()
        try await sql.raw("DROP FUNCTION \(unsafeRaw: name)()").run()
        throw error
    }
    try await sql.raw("DROP TRIGGER \(unsafeRaw: name) ON \(unsafeRaw: table)").run()
    try await sql.raw("DROP FUNCTION \(unsafeRaw: name)()").run()
}
