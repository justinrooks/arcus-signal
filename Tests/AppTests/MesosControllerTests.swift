@testable import App
import ArcusCore
import FluentSQL
import Foundation
import Testing
import Vapor
import VaporTesting

@Suite("Meso API reads", .serialized, .sharedDatabase)
struct MesosControllerTests {
    private let cell: Int64 = 614553222213795839
    private let otherCell: Int64 = 614553222215892991

    private func product(number: Int, start: Date, end: Date, sparse: Bool = false, issuedOffset: TimeInterval = 0) -> MesoscaleDiscussionPayload {
        MesoscaleDiscussionPayload(
            number: number, title: "SPC MD \(number)",
            sourceURL: URL(string: "https://www.spc.noaa.gov/products/md/md\(number).html")!,
            issued: Date(timeIntervalSince1970: -5238518400).addingTimeInterval(issuedOffset),
            validStart: start, validEnd: end, areasAffected: "Colorado", summary: "Discussion text",
            concerning: sparse ? nil : "Severe potential", watchProbability: sparse ? nil : 80,
            watchProbabilityText: sparse ? "Unknown" : "80 percent",
            threats: sparse ? nil : .init(peakWindMPH: 70, hailRangeInches: 2, tornadoStrength: "Strong"),
            coordinates: sparse ? [] : [
                .init(latitude: 39, longitude: -105), .init(latitude: 40, longitude: -105),
                .init(latitude: 40, longitude: -104), .init(latitude: 39, longitude: -105)
            ]
        )
    }

    private func withApp(_ test: (Application, Date) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            // Remove fixtures left behind by an interrupted earlier run. The shared-database
            // trait prevents another database-backed suite from writing while this suite runs.
            try await SPCMesoModel.query(on: app.db).filter(\.$issueYear == 1804).delete()
            do { try await test(app, Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))) }
            catch {
                try await SPCMesoModel.query(on: app.db).filter(\.$issueYear == 1804).delete()
                throw error
            }
            try await SPCMesoModel.query(on: app.db).filter(\.$issueYear == 1804).delete()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func seed(_ payload: MesoscaleDiscussionPayload, cells: [Int64], on app: Application) async throws {
        #expect(payload.issueYear == 1804)
        let row = SPCMesoModel(product: payload, contentFingerprint: "fixture", seenAt: .now)
        try await row.create(on: app.db)
        if !payload.coordinates.isEmpty {
            let geo = SPCMesoGeolocationModel(
                mesoID: try row.requireID(),
                geometry: .polygon(rings: [payload.coordinates.map { .init(lon: $0.longitude, lat: $0.latitude) }]),
                geometryHash: "fixture"
            )
            geo.h3Cells = cells
            geo.h3Resolution = 8
            geo.h3Hash = "fixture"
            try await geo.create(on: app.db)
        }
    }

    @Test func modesRoundTripAndLifecycleBoundaries() async throws {
        try await withApp { app, now in
            let local = product(number: 1, start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3600))
            let remote = product(number: 2, start: local.validStart, end: local.validEnd, issuedOffset: 60)
            let sparse = product(number: 3, start: local.validStart, end: local.validEnd, sparse: true)
            let expired = product(number: 4, start: local.validStart, end: now)
            let future = product(number: 5, start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200))
            for (payload, cells) in [(local, [cell]), (remote, [otherCell]), (sparse, []), (expired, [cell]), (future, [cell])] {
                try await seed(payload, cells: cells, on: app)
            }
            let sql = try #require(app.db as? any SQLDatabase)
            let active = try await loadMesos(sql: sql, productID: nil, h3: nil, evaluatedAt: now)
            let fixtureIDs = Set(active.filter { $0.issueYear == 1804 }.map(\.productID))
            #expect(fixtureIDs == [local.productID, remote.productID, sparse.productID])
            #expect(active.filter { $0.issueYear == 1804 }.map(\.productID) == [remote.productID, local.productID, sparse.productID])
            #expect(active.contains(local))
            #expect(active.contains(sparse))
            let scoped = try await loadMesos(sql: sql, productID: nil, h3: cell, evaluatedAt: now)
            #expect(scoped.filter { $0.issueYear == 1804 } == [local])
            let atStart = try await loadMesos(sql: sql, productID: nil, h3: nil, evaluatedAt: future.validStart)
            #expect(atStart.contains(future) && !atStart.contains(local))
            for path in ["v1/mesos", "api/v1/mesos"] {
                try await app.testing().test(.GET, "\(path)?id=\(expired.productID)", afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let payload = try JSONDecoder().decode([MesoscaleDiscussionPayload].self, from: Data(res.body.readableBytesView))
                    #expect(payload == [expired])
                    #expect(res.headers.contentType == .json)
                })
                try await app.testing().test(.GET, path, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let payload = try JSONDecoder().decode([MesoscaleDiscussionPayload].self, from: Data(res.body.readableBytesView))
                    #expect(Set(payload.filter { $0.issueYear == 1804 }.map(\.productID)) == fixtureIDs)
                })
                try await app.testing().test(.GET, "\(path)?h3=\(cell)", afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let payload = try JSONDecoder().decode([MesoscaleDiscussionPayload].self, from: Data(res.body.readableBytesView))
                    #expect(payload.filter { $0.issueYear == 1804 } == [local])
                })
            }
        }
    }

    @Test func conditionalReadsTrackContentGeometryAndExpiry() async throws {
        try await withApp { app, now in
            let payload = product(number: 1, start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3600))
            try await seed(payload, cells: [cell], on: app)
            let request = Request(application: app, method: .GET, url: "/v1/mesos?id=\(payload.productID)", on: app.eventLoopGroup.next())
            let controller = MesosController()
            let first = try await controller.index(req: request)
            let etag = try #require(first.headers.first(name: .eTag))
            try await app.testing().test(.GET, "v1/mesos?id=\(payload.productID)", headers: ["If-None-Match": etag], afterResponse: { res async in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
                #expect(res.headers.first(name: .eTag) == etag)
            })
            let observed = try #require(try await SPCMesoModel.query(on: app.db).filter(\.$productKey == payload.productID).first())
            observed.lastSeen = now.addingTimeInterval(30)
            try await observed.update(on: app.db)
            #expect(try await controller.index(req: request).headers.first(name: .eTag) == etag)
            for tag in [etag, "\"other\", \(etag)", String(etag.dropFirst(2)), "*"] {
                request.headers.replaceOrAdd(name: .ifNoneMatch, value: tag)
                let conditional = try await controller.index(req: request)
                #expect(conditional.status == .notModified)
                #expect((conditional.body.string ?? "").isEmpty)
                #expect(conditional.headers.first(name: .eTag) == etag)
            }
            request.headers.replaceOrAdd(name: .ifNoneMatch, value: etag)
            let row = try #require(try await SPCMesoModel.query(on: app.db).filter(\.$productKey == payload.productID).first())
            row.summary = "Updated discussion"
            try await row.update(on: app.db)
            let changed = try await controller.index(req: request)
            #expect(changed.status == .ok && changed.headers.first(name: .eTag) != etag)
            let geo = try #require(try await SPCMesoGeolocationModel.query(on: app.db).filter(\.$meso.$id == row.requireID()).first())
            geo.geometry = .polygon(rings: [[.init(lon: -106, lat: 39), .init(lon: -106, lat: 40), .init(lon: -105, lat: 40), .init(lon: -106, lat: 39)]])
            try await geo.update(on: app.db)
            let geometryChanged = try await controller.index(req: request)
            #expect(geometryChanged.headers.first(name: .eTag) != changed.headers.first(name: .eTag))
            let collection = Request(application: app, method: .GET, url: "/v1/mesos", on: app.eventLoopGroup.next())
            let beforeExpiry = try await controller.index(req: collection)
            collection.headers.replaceOrAdd(name: .ifNoneMatch, value: try #require(beforeExpiry.headers.first(name: .eTag)))
            row.validEnd = now.addingTimeInterval(-1)
            try await row.update(on: app.db)
            let afterExpiry = try await controller.index(req: collection)
            #expect(afterExpiry.status == .ok)
            #expect(afterExpiry.headers.first(name: .eTag) != beforeExpiry.headers.first(name: .eTag))
        }
    }

    @Test func invalidAndAbsentReads() async throws {
        try await withApp { app, _ in
            for query in ["id=123", "id=", "id=SPC-MD-2026-0123", "id=SPC-MD-2026-123&h3=\(cell)",
                          "h3=", "h3=abc", "h3=-1", "h3=0", "h3=1", "h3=9223372036854775808", "h3=577199624117288959", "h3=617700169958293503"] {
                try await app.testing().test(.GET, "v1/mesos?\(query)", afterResponse: { res async in
                    #expect(res.status == .badRequest)
                })
            }
            try await app.testing().test(.GET, "v1/mesos?id=SPC-MD-1804-9999", afterResponse: { res async in
                #expect(res.status == .notFound)
            })
            try await app.testing().test(.GET, "v1/mesos?h3=\(cell)", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "[]")
                #expect(res.headers.first(name: .eTag) != nil)
            })
            let sql = try #require(app.db as? any SQLDatabase)
            let empty = try await loadMesos(sql: sql, productID: nil, h3: nil, evaluatedAt: Date(timeIntervalSince1970: -10_000_000_000))
            #expect(empty.isEmpty)
        }
    }
}
