@testable import App
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor

@Suite("Meso durable delivery identity", .serialized, .sharedDatabase)
struct MesoDeliveryIdentityTests {
    private let store = NotificationDeliveryStore()

    private func installation(on db: any Database) async throws -> UUID {
        let id = UUID()
        try await DeviceInstallationModel(
            installationId: id, apnsDeviceToken: "meso-identity-test",
            apnsEnvironment: .sandbox, platform: .iOS, osVersion: "26",
            appVersion: "1", buildNumber: "1", locationAuth: .always,
            lastSeenAt: .now, isSubscribed: true
        ).create(on: db)
        return id
    }

    private func claim(_ installation: UUID, year: Int = 2026, number: Int = 1234,
                       origin: NotificationDeliveryOrigin = .alertDriven,
                       mode: NotificationTargetMode = .h3, reason: NotificationReason = .new,
                       owner: String = "event-job", on db: any Database) async throws -> LedgerClaimResult {
        try await store.claimMeso(
            installationID: installation, issueYear: year, number: number, mode: mode,
            reason: reason, freshnessState: .fresh, retryOwnerID: owner, origin: origin, on: db
        )
    }

    @Test("canonical snapshot changes do not change the shared delivery subject")
    func contentIdentity() throws {
        let url = try #require(Bundle.module.url(forResource: "meso", withExtension: "xml", subdirectory: "Fixtures/SPC"))
        let product = try #require(SPCMesoParser.parse(Data(contentsOf: url)).first)
        let meso = SPCMesoModel(product: product, contentFingerprint: "original", seenAt: .distantPast)
        let original = NotificationSubject.spcMeso(issueYear: product.issueYear, number: product.number)
        #expect(original.productID == product.productID)
        #expect(original.revisionID == "initial")
        meso.summary = "Updated canonical content"
        meso.watchProbability = 10
        meso.contentFingerprint = "changed"
        meso.lastSeen = .distantFuture
        // Persisted lookup and fresh ingestion supply only year/number; geometry
        // and H3 coverage cannot enter this helper or the claim API.
        #expect(NotificationSubject.spcMeso(issueYear: meso.issueYear, number: meso.number) == original)
        #expect(NotificationSubject.spcMeso(issueYear: product.issueYear + 1, number: product.number) != original)
        #expect(NotificationSubject.spcMeso(issueYear: product.issueYear, number: product.number + 1) != original)
    }

    @Test("duplicate ingest, updated discussion and either producer order share one claim",
          arguments: [NotificationDeliveryOrigin.alertDriven, .presenceReconciliation])
    func producerOrders(firstOrigin: NotificationDeliveryOrigin) async throws {
        try await withIntegrationTestApplication(setup: .configured(mode: .api, migrate: true)) { app in
            try await withRollbackTransaction(on: app) { db in
                let id = try await installation(on: db)
                let first = try await claim(id, origin: firstOrigin, on: db)
                #expect(first.inserted && first.retryGeneration == 0)
                let ledgerID = try #require(first.id)
                let otherOrigin: NotificationDeliveryOrigin = firstOrigin == .alertDriven ? .presenceReconciliation : .alertDriven
                for origin in [firstOrigin, otherOrigin] {
                    for mode in [NotificationTargetMode.h3, .ugc] {
                        let duplicate = try await claim(id, origin: origin, mode: mode, reason: .update,
                                                        owner: "other-job", on: db)
                        #expect(!duplicate.inserted && duplicate.id == nil && duplicate.retryGeneration == nil)
                    }
                }
                let row = try #require(try await NotificationLedgerModel.find(ledgerID, on: db))
                #expect(row.subject == .spcMeso(issueYear: 2026, number: 1234))
                #expect(row.status == "claimed" && row.completedAt == nil)
                let sql = try #require(db as? any SQLDatabase)
                let persistedOrigin = try #require(try await sql.raw("SELECT delivery_origin FROM notification_ledger WHERE id = \(bind: ledgerID)").first())
                #expect(try persistedOrigin.decode(column: "delivery_origin", as: String.self) == firstOrigin.rawValue)
                try await store.completeSent(claimID: ledgerID, on: db)
                #expect(!(try await claim(id, origin: otherOrigin, on: db)).inserted)
                #expect(try await claim(id, year: 2027, on: db).inserted)
                #expect(try await claim(id, number: 1235, on: db).inserted)
                let otherInstallation = try await installation(on: db)
                #expect(try await claim(otherInstallation, on: db).inserted)
                #expect(try await NotificationLedgerModel.query(on: db).filter(\.$deviceInstallation.$id == id).count() == 3)
            }
        }
    }

    @Test("ineligible and exhausted retries terminalize only the matching owned discussion")
    func terminalRetries() async throws {
        try await withIntegrationTestApplication(setup: .configured(mode: .api, migrate: true)) { app in
            try await withRollbackTransaction(on: app) { db in
                let id = try await installation(on: db)
                for number in [1234, 1235] {
                    let claimed = try await claim(id, number: number, on: db)
                    try await store.markRetrying(claimID: claimed.id, retryOwnerID: "event-job",
                            retryGeneration: claimed.retryGeneration, apnsErrorCode: "ServiceUnavailable", on: db)
                }
                let retry = try #require(try await store.loadRetryingMesoDeliveries(
                        issueYear: 2026, number: 1234, retryOwnerID: "event-job", on: db).first)
                #expect(!(try await store.completeRetryingMesoFailure(retry, issueYear: 2026, number: 1235,
                        retryOwnerID: "event-job", apnsErrorCode: "ineligible", on: db)))
                #expect(!(try await store.completeRetryingMesoFailure(retry, issueYear: 2026, number: 1234,
                        retryOwnerID: "wrong-owner", apnsErrorCode: "ineligible", on: db)))
                let foreignRetry = NotificationRetryDelivery(id: retry.id, installationID: UUID(),
                                                             retryGeneration: retry.retryGeneration)
                #expect(!(try await store.completeRetryingMesoFailure(foreignRetry, issueYear: 2026, number: 1234,
                        retryOwnerID: "event-job", apnsErrorCode: "ineligible", on: db)))
                #expect(try await NotificationLedgerModel.find(retry.id, on: db)?.status == "retrying")
                #expect(try await store.completeRetryingMesoFailure(retry, issueYear: 2026, number: 1234,
                        retryOwnerID: "event-job", apnsErrorCode: "ineligible", on: db))
                #expect(!(try await store.completeRetryingMesoFailure(retry, issueYear: 2026, number: 1234,
                        retryOwnerID: "event-job", apnsErrorCode: "ineligible", on: db)))
                #expect(try await store.failRetryingMesoDeliveries(issueYear: 2026, number: 1235,
                        retryOwnerID: "wrong-owner", apnsErrorCode: "exhausted", on: db) == 0)
                #expect(try await store.failRetryingMesoDeliveries(issueYear: 2027, number: 1235,
                        retryOwnerID: "event-job", apnsErrorCode: "exhausted", on: db) == 0)
                #expect(try await store.failRetryingMesoDeliveries(issueYear: 2026, number: 1235,
                        installationID: UUID(), retryOwnerID: "event-job", apnsErrorCode: "exhausted", on: db) == 0)
                #expect(try await store.failRetryingMesoDeliveries(issueYear: 2026, number: 1235,
                        installationID: id, retryOwnerID: "event-job", apnsErrorCode: "exhausted", on: db) == 1)
                let rows = try await NotificationLedgerModel.query(on: db).filter(\.$deviceInstallation.$id == id).all()
                #expect(rows.count == 2)
                #expect(rows.allSatisfy { $0.status == "failed" && $0.completedAt != nil })
                #expect(!(try await claim(id, on: db)).inserted)
                #expect(!(try await claim(id, number: 1235, on: db)).inserted)
            }
        }
    }

    @Test("simultaneous jobs have one winner and only the owning retry reuses that row")
    func concurrentClaimsAndRetry() async throws {
        try await withIntegrationTestApplication(setup: .configured(mode: .api, migrate: true)) { app in
            // Committed fixture and independent pool connections are required for
            // a real unique-index race, rather than two queries on one transaction.
            let id = try await installation(on: app.db)
            do {
                async let event = claim(id, owner: "event-job", on: app.db)
                async let presence = claim(id, origin: .presenceReconciliation, mode: .ugc,
                                           owner: "presence-job", on: app.db)
                let results = try await [event, presence]
                #expect(results.filter(\.inserted).count == 1)
                let winner = try #require(results.first(where: { $0.inserted }))
                let ledgerID = try #require(winner.id)
                let row = try #require(try await NotificationLedgerModel.find(ledgerID, on: app.db))
                #expect(row.status == "claimed")
                let sql = try #require(app.db as? any SQLDatabase)
                let ownership = try #require(try await sql.raw("SELECT retry_owner_id FROM notification_ledger WHERE id = \(bind: ledgerID)").first())
                let owner = try ownership.decode(column: "retry_owner_id", as: String.self)
                try await store.markRetrying(claimID: ledgerID, retryOwnerID: owner,
                                             retryGeneration: winner.retryGeneration,
                                             apnsErrorCode: "ServiceUnavailable", on: app.db)
                let retry = try #require(try await store.loadRetryingMesoDeliveries(
                    issueYear: 2026, number: 1234, installationID: id, retryOwnerID: owner, on: app.db).first)
                #expect(retry.id == ledgerID && retry.retryGeneration == 1)
                #expect(try await store.loadRetryingMesoDeliveries(issueYear: 2026, number: 1234,
                        retryOwnerID: "wrong-owner", on: app.db).isEmpty)
                #expect(try await store.loadRetryingMesoDeliveries(issueYear: 2027, number: 1234,
                        retryOwnerID: owner, on: app.db).isEmpty)
                #expect(try await store.loadRetryingMesoDeliveries(issueYear: 2026, number: 1234,
                        installationID: UUID(), retryOwnerID: owner, on: app.db).isEmpty)
                #expect(!(try await store.hasMesoRetryInFlight(issueYear: 2026, number: 1234,
                        retryOwnerID: owner, on: app.db)))
                #expect(!(try await claim(id, owner: "new-job", on: app.db)).inserted)
                let retrying = try #require(try await NotificationLedgerModel.find(ledgerID, on: app.db))
                #expect(retrying.status == "retrying" && retrying.completedAt == nil)
                #expect(!(try await store.reclaimRetryingMeso(retry, issueYear: 2026, number: 1234,
                        retryOwnerID: "wrong-owner", freshnessState: .fresh, on: app.db)).inserted)
                #expect(!(try await store.reclaimRetryingMeso(retry, issueYear: 2027, number: 1234,
                        retryOwnerID: owner, freshnessState: .fresh, on: app.db)).inserted)
                let wrongInstallation = NotificationRetryDelivery(id: ledgerID, installationID: UUID(), retryGeneration: 1)
                #expect(!(try await store.reclaimRetryingMeso(wrongInstallation, issueYear: 2026, number: 1234,
                        retryOwnerID: owner, freshnessState: .fresh, on: app.db)).inserted)
                let stale = NotificationRetryDelivery(id: ledgerID, installationID: id, retryGeneration: 0)
                #expect(!(try await store.reclaimRetryingMeso(stale, issueYear: 2026, number: 1234,
                        retryOwnerID: owner, freshnessState: .fresh, on: app.db)).inserted)
                async let left = store.reclaimRetryingMeso(retry, issueYear: 2026, number: 1234,
                        retryOwnerID: owner, freshnessState: .fresh, on: app.db)
                async let right = store.reclaimRetryingMeso(retry, issueYear: 2026, number: 1234,
                        retryOwnerID: owner, freshnessState: .fresh, on: app.db)
                let reclaimed = try await [left, right]
                #expect(reclaimed.filter(\.inserted).count == 1)
                #expect(reclaimed.first(where: { $0.inserted })?.id == ledgerID)
                #expect(reclaimed.first(where: { $0.inserted })?.retryGeneration == 1)
                #expect(try await store.hasMesoRetryInFlight(issueYear: 2026, number: 1234,
                        retryOwnerID: owner, on: app.db))
                #expect(try await store.hasMesoRetryInFlight(issueYear: 2026, number: 1234,
                        installationID: id, retryOwnerID: owner, on: app.db))
                #expect(!(try await store.hasMesoRetryInFlight(issueYear: 2026, number: 1234,
                        installationID: UUID(), retryOwnerID: owner, on: app.db)))
                #expect(!(try await store.hasMesoRetryInFlight(issueYear: 2026, number: 1234,
                        retryOwnerID: "wrong-owner", on: app.db)))
                #expect(try await store.loadRetryingMesoDeliveries(issueYear: 2026, number: 1234,
                        retryOwnerID: owner, on: app.db).isEmpty)
                try await store.completeSent(claimID: ledgerID, on: app.db)
                let sent = try #require(try await NotificationLedgerModel.find(ledgerID, on: app.db))
                #expect(sent.status == "sent" && sent.completedAt != nil)
                #expect(sent.subject == .spcMeso(issueYear: 2026, number: 1234))
                #expect(try await NotificationLedgerModel.query(on: app.db).filter(\.$deviceInstallation.$id == id).count() == 1)
            } catch {
                try await NotificationLedgerModel.query(on: app.db).filter(\.$deviceInstallation.$id == id).delete()
                try await DeviceInstallationModel.find(id, on: app.db)?.delete(on: app.db)
                throw error
            }
            try await NotificationLedgerModel.query(on: app.db).filter(\.$deviceInstallation.$id == id).delete()
            try await DeviceInstallationModel.find(id, on: app.db)?.delete(on: app.db)
        }
    }
}
