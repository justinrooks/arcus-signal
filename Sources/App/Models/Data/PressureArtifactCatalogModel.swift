import Fluent
import Foundation

enum PressureArtifactCatalogStatus: String, Codable, Sendable {
    case pending
    case warming
    case ready
    case failed
    case expired
}

enum PressureArtifactCatalogSource: String, Codable, Sendable {
    case aws
    case nomads
    case unknown
}

final class PressureArtifactCatalogModel: Model, @unchecked Sendable {
    static let schema = "pressure_artifact_catalog"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "run_time")
    var runTime: Date

    @Field(key: "forecast_hour")
    var forecastHour: Int

    @Field(key: "valid_time")
    var validTime: Date

    @Field(key: "product")
    var productRaw: String

    @Field(key: "field_set_version")
    var fieldSetVersionRaw: String

    @Field(key: "status")
    var statusRaw: String

    @OptionalField(key: "local_path")
    var localPath: String?

    @OptionalField(key: "byte_size")
    var byteSize: Int64?

    @OptionalField(key: "claim_token")
    var claimToken: UUID?

    @OptionalField(key: "lease_expires_at")
    var leaseExpiresAt: Date?

    @Field(key: "source")
    var sourceRaw: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @OptionalField(key: "last_checked_at")
    var lastCheckedAt: Date?

    @OptionalField(key: "error_summary")
    var errorSummary: String?

    init() {}

    init(
        id: UUID? = nil,
        runTime: Date,
        forecastHour: Int,
        validTime: Date,
        product: HrrrProduct,
        fieldSetVersion: HrrrFieldSetVersion? = nil,
        status: PressureArtifactCatalogStatus = .pending,
        localPath: String? = nil,
        byteSize: Int64? = nil,
        claimToken: UUID? = nil,
        leaseExpiresAt: Date? = nil,
        source: PressureArtifactCatalogSource = .unknown,
        lastCheckedAt: Date? = nil,
        errorSummary: String? = nil
    ) {
        self.id = id
        self.runTime = runTime
        self.forecastHour = forecastHour
        self.validTime = validTime
        self.productRaw = product.rawValue
        self.fieldSetVersionRaw = (fieldSetVersion ?? product.defaultFieldSetVersion).rawValue
        self.statusRaw = status.rawValue
        self.localPath = localPath
        self.byteSize = byteSize
        self.claimToken = claimToken
        self.leaseExpiresAt = leaseExpiresAt
        self.sourceRaw = source.rawValue
        self.lastCheckedAt = lastCheckedAt
        self.errorSummary = errorSummary
    }
}

extension PressureArtifactCatalogModel {
    var status: PressureArtifactCatalogStatus {
        get { PressureArtifactCatalogStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var product: HrrrProduct {
        get { HrrrProduct(rawValue: productRaw) ?? .wrfprsf }
        set { productRaw = newValue.rawValue }
    }

    var fieldSetVersion: HrrrFieldSetVersion {
        get { HrrrFieldSetVersion(rawValue: fieldSetVersionRaw) ?? product.defaultFieldSetVersion }
        set { fieldSetVersionRaw = newValue.rawValue }
    }

    var source: PressureArtifactCatalogSource {
        get { PressureArtifactCatalogSource(rawValue: sourceRaw) ?? .unknown }
        set { sourceRaw = newValue.rawValue }
    }

    static func find(
        runTime: Date,
        forecastHour: Int,
        product: HrrrProduct,
        fieldSetVersion: HrrrFieldSetVersion,
        on database: any Database
    ) async throws -> PressureArtifactCatalogModel? {
        try await query(on: database)
            .filter(\.$runTime == runTime)
            .filter(\.$forecastHour == forecastHour)
            .filter(\.$productRaw == product.rawValue)
            .filter(\.$fieldSetVersionRaw == fieldSetVersion.rawValue)
            .first()
    }
}
