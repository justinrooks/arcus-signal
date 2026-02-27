//import Fluent
//
//#warning("DEPRECATED")
//public struct CreateArcusEventModel: AsyncMigration {
//    public init() {}
//
//    public func prepare(on database: any Database) async throws {
//        try await database.schema(ArcusEventModel.schema)
//            .id()
//            .field("event_key", .string, .required)
//            .field("source", .string, .required)
//            .field("kind", .string, .required)
//            .field("source_url", .string, .required)
//            .field("status", .string, .required)
//            .field("revision", .int, .required)
//            .field("issued_at", .datetime)
//            .field("effective_at", .datetime)
//            .field("expires_at", .datetime)
//            .field("severity", .string, .required)
//            .field("urgency", .string, .required)
//            .field("certainty", .string, .required)
//            .field("geometry_json", .string)
//            .field("ugc_codes", .array(of: .string), .required)
//            .field("h3_resolution", .int)
//            .field("h3_cover_hash", .string)
//            .field("title", .string)
//            .field("area_desc", .string)
//            .field("raw_ref", .string)
//            .field("created_at", .datetime)
//            .field("updated_at", .datetime)
//            .unique(on: "event_key", "revision")
//            .create()
//    }
//
//    public func revert(on database: any Database) async throws {
//        try await database.schema(ArcusEventModel.schema).delete()
//    }
//}
