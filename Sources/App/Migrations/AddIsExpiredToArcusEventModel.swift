//import Fluent
//
//#warning("DEPRECATED")
//public struct AddIsExpiredToArcusEventModel: AsyncMigration {
//    public init() {}
//
//    public func prepare(on database: any Database) async throws {
//        try await database.schema(ArcusEventModel.schema)
//            .field("is_expired", .bool, .required, .sql(.default(false)))
//            .update()
//    }
//
//    public func revert(on database: any Database) async throws {
//        try await database.schema(ArcusEventModel.schema)
//            .deleteField("is_expired")
//            .update()
//    }
//}
