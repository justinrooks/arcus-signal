import Foundation

struct AnvilAnalyzeProfileResponse: Codable, Sendable, Equatable {
    let effectiveLayer: AnvilEffectiveLayerDTO
    let stormMotion: AnvilStormMotionDTO
    let mucape: Double?
    let mlcape: Double?
    let mlcin: Double?
    let mllclMetersAgl: Double?
    let effectiveSrh: Double?
    let effectiveBulkShearMs: Double?
    let scp: Double?
    let stpCin: Double?
    let stpFixed: Double?
    let ship: Double?
    let srh01km: Double?
    let srh03km: Double?
    let sbcape: Double?
    let sbcin: Double?
    let bulkShear06kmMs: Double?
    let lapserate03km: Double?
    let threeCapeJkg: Double?
    
    let quality: AnvilQualityDTO
}

struct AnvilEffectiveLayerDTO: Codable, Sendable, Equatable {
    let status: String
    let basePressureMb: Double?
    let topPressureMb: Double?
    let baseMetersAgl: Double?
    let topMetersAgl: Double?
}

struct AnvilQualityDTO: Codable, Sendable, Equatable {
    let profileLevelCount: Int
    let warnings: [String]
}

struct AnvilStormMotionDTO: Codable, Sendable, Equatable {
    let status: String
    let bunkersRight: AnvilBunkersRightStormMotionDTO?
}

struct AnvilBunkersRightStormMotionDTO: Codable, Sendable, Equatable {
    let uKt: Double
    let vKt: Double
    let speedKt: Double
    let directionTowardDeg: Double
    let uMs: Double
    let vMs: Double
    let speedMs: Double
}
