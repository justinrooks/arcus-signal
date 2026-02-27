//import Fluent
//
//#warning("DEPRECATED")
//public struct AddContentHashToArcusEventModel: AsyncMigration {
//    public init() {}
//
//    public func prepare(on database: any Database) async throws {
//        try await database.schema(ArcusEventModel.schema)
//            .field("content_hash", .string, .required, .sql(.default("")))
//            .update()
//    }
//
//    public func revert(on database: any Database) async throws {
//        try await database.schema(ArcusEventModel.schema)
//            .deleteField("content_hash")
//            .update()
//    }
//}
