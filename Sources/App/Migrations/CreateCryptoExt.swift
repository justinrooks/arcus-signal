//
//  CreateCryptoExt.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/27/26.
//

import Fluent
import SQLKit

struct CreatePgcryptoExtension: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS pgcrypto;").run()
    }
    
    func revert(on database: any Database) async throws {
        // Ignore. dont want to break stuff
    }
}
