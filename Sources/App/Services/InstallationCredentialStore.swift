import Fluent
import FluentSQL
import Vapor

/// Independent of delivery registration: enrollment never creates an APNs binding.
enum InstallationCredentialStore {
    static let schema = "installation_credentials"

    static func verifier(for credential: String) -> String? {
        // Accept canonical unpadded or padded base64url, representing exactly 256 bits.
        let unpadded = credential.hasSuffix("=") ? String(credential.dropLast()) : credential
        guard unpadded.utf8.count == 43,
              unpadded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let bytes = Data(base64Encoded: unpadded.replacingOccurrences(of: "-", with: "+")
                  .replacingOccurrences(of: "_", with: "/") + "="),
              bytes.count == 32,
              bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                  .replacingOccurrences(of: "/", with: "_").dropLast() == unpadded else {
            return nil
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func lock(_ id: UUID, on database: any Database) async throws {
        guard database.inTransaction, let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Credential authority requires a SQL transaction")
        }
        // Also serializes UUIDs without rows. Hash collisions only serialize unrelated writers.
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: id.uuidString.lowercased()), 386))").run()
    }

    static func load(_ id: UUID, on database: any Database) async throws -> String? {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        let row = try await sql.raw("SELECT verifier FROM installation_credentials WHERE installation_id = \(bind: id)").first()
        return try row?.decode(column: "verifier", as: String.self)
    }

    /// Caller holds the installation lock until transaction completion.
    static func enroll(_ id: UUID, verifier: String, on database: any Database) async throws {
        if let existing = try await load(id, on: database) {
            guard existing.utf8.secureCompare(to: verifier.utf8) else { throw Abort(.conflict) }
            return
        }
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("""
            INSERT INTO installation_credentials (installation_id, verifier)
            VALUES (\(bind: id), \(bind: verifier))
            """).run()
    }
}

extension Application {
    private struct DeviceLegacyWritesKey: StorageKey { typealias Value = Bool }

    var deviceLegacyWritesEnabled: Bool {
        get { storage[DeviceLegacyWritesKey.self] ?? true }
        set { storage[DeviceLegacyWritesKey.self] = newValue }
    }
}
