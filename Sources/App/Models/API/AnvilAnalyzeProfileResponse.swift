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

    init(
        effectiveLayer: AnvilEffectiveLayerDTO,
        stormMotion: AnvilStormMotionDTO,
        mucape: Double?,
        mlcape: Double?,
        mlcin: Double?,
        mllclMetersAgl: Double?,
        effectiveSrh: Double?,
        effectiveBulkShearMs: Double?,
        scp: Double?,
        stpCin: Double?,
        stpFixed: Double?,
        ship: Double?,
        srh01km: Double? = nil,
        srh03km: Double? = nil,
        sbcape: Double? = nil,
        sbcin: Double? = nil,
        bulkShear06kmMs: Double? = nil,
        lapserate03km: Double? = nil,
        threeCapeJkg: Double? = nil,
        quality: AnvilQualityDTO
    ) {
        self.effectiveLayer = effectiveLayer
        self.stormMotion = stormMotion
        self.mucape = mucape
        self.mlcape = mlcape
        self.mlcin = mlcin
        self.mllclMetersAgl = mllclMetersAgl
        self.effectiveSrh = effectiveSrh
        self.effectiveBulkShearMs = effectiveBulkShearMs
        self.scp = scp
        self.stpCin = stpCin
        self.stpFixed = stpFixed
        self.ship = ship
        self.srh01km = srh01km
        self.srh03km = srh03km
        self.sbcape = sbcape
        self.sbcin = sbcin
        self.bulkShear06kmMs = bulkShear06kmMs
        self.lapserate03km = lapserate03km
        self.threeCapeJkg = threeCapeJkg
        self.quality = quality
    }
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
