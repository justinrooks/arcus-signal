import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor

/// Fault injection after a real ledger claim/reclaim, before the new consent read.
/// Shared-database suites serialize this temporary DDL; no production hook is needed.
func withConsentClaimBoundary(
    installationID: UUID, readFailure: Bool, on db: any Database,
    test: () async throws -> Void
) async throws {
    let name = Environment.get("DATABASE_URL").flatMap(URL.init(string:))?.lastPathComponent ?? ""
    guard name.range(of: #"^arcus_issue[0-9]+_(test|validation)_[A-Za-z0-9_]+$"#, options: .regularExpression) != nil else {
        throw Abort(.internalServerError, reason: "An explicitly issue-scoped isolated test database is required")
    }
    let sql = try #require(db as? any SQLDatabase)
    let action = readFailure ? "ALTER TABLE device_installations RENAME TO issue389_hidden_installations;" :
        "UPDATE device_installations SET consent_revision = 2, location_sharing_enabled = FALSE WHERE installation_id = NEW.installation_id;"
    try await sql.raw("""
        CREATE FUNCTION issue389_claim_boundary() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN \(unsafeRaw: action) RETURN NEW; END $$
        """).run()
    try await sql.raw("""
        CREATE TRIGGER issue389_claim_boundary AFTER INSERT OR UPDATE ON notification_ledger
        FOR EACH ROW WHEN (NEW.installation_id = '\(unsafeRaw: installationID.uuidString)'::uuid AND NEW.status = 'claimed')
        EXECUTE FUNCTION issue389_claim_boundary()
        """).run()
    func restore() async throws {
        try await sql.raw("DROP TRIGGER issue389_claim_boundary ON notification_ledger").run()
        try await sql.raw("DROP FUNCTION issue389_claim_boundary()").run()
        if readFailure { try await sql.raw("ALTER TABLE IF EXISTS issue389_hidden_installations RENAME TO device_installations").run() }
    }
    do { try await test(); try await restore() }
    catch { try? await restore(); throw error }
}
