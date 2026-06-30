@testable import App
import Foundation
import Testing

@Suite("Anvil surface profile normalizer", .serialized)
struct AnvilSurfaceProfileNormalizerTests {
    @Test("response values normalize into stable evidence bands and diagnostics")
    func responseValuesNormalizeIntoStableEvidenceBandsAndDiagnostics() {
        let evidence = AnvilSurfaceProfileNormalizer().normalize(response: makeResponse(
            scp: 0.2130911716615775,
            stpCin: 0.0,
            stpFixed: 2.4,
            ship: 0.6,
            profileLevelCount: 20,
            warnings: []
        ))

        #expect(evidence.scp?.support == .weak)
        #expect(evidence.stp?.support == .supportive)
        #expect(evidence.ship?.support == .conditional)
        #expect(evidence.status == .available)
        #expect(evidence.reason == nil)
        #expect(evidence.diagnostics.hasEffectiveLayer)
        #expect(evidence.diagnostics.hasStormMotion)
        #expect(evidence.diagnostics.qualityProfileLevelCount == 20)
        #expect(evidence.diagnostics.warnings.isEmpty)
        #expect(!evidence.isDegraded)
        #expect(evidence.strongestSupport == .supportive)
    }

    @Test("additional warnings keep the same bands but mark evidence degraded")
    func additionalWarningsMarkEvidenceDegraded() {
        let evidence = AnvilSurfaceProfileNormalizer().normalize(
            response: makeResponse(
                scp: 4.2,
                stpCin: 0.0,
                stpFixed: 3.4,
                ship: 1.5,
                profileLevelCount: 20,
                warnings: []
            ),
            additionalWarnings: ["profile cache stale"]
        )

        #expect(evidence.scp?.support == .strong)
        #expect(evidence.stp?.support == .strong)
        #expect(evidence.ship?.support == .supportive)
        #expect(evidence.status == .degraded)
        #expect(evidence.reason == nil)
        #expect(evidence.diagnostics.warnings == ["profile cache stale"])
        #expect(evidence.isDegraded)
    }

    @Test("missing values and degraded diagnostics remain visible as degraded evidence")
    func missingValuesAndDegradedDiagnosticsRemainVisibleAsDegradedEvidence() {
        let evidence = AnvilSurfaceProfileNormalizer().normalize(response: makeResponse(
            scp: nil,
            stpCin: nil,
            stpFixed: nil,
            ship: nil,
            effectiveLayerStatus: "notFound",
            stormMotionStatus: "notComputed",
            profileLevelCount: 3,
            warnings: ["profile incomplete"]
        ))

        #expect(evidence.scp == nil)
        #expect(evidence.stp == nil)
        #expect(evidence.ship == nil)
        #expect(evidence.status == .degraded)
        #expect(evidence.supportCount == 0)
        #expect(evidence.strongestSupport == nil)
        #expect(evidence.isDegraded)
        #expect(!evidence.diagnostics.hasEffectiveLayer)
        #expect(!evidence.diagnostics.hasStormMotion)
        #expect(evidence.diagnostics.isDegraded)
    }

    private func makeResponse(
        scp: Double?,
        stpCin: Double?,
        stpFixed: Double?,
        ship: Double?,
        effectiveLayerStatus: String = "found",
        stormMotionStatus: String = "computed",
        profileLevelCount: Int,
        warnings: [String]
    ) -> AnvilAnalyzeProfileResponse {
        AnvilAnalyzeProfileResponse(
            effectiveLayer: AnvilEffectiveLayerDTO(
                status: effectiveLayerStatus,
                basePressureMb: 1000,
                topPressureMb: 925,
                baseMetersAgl: 0,
                topMetersAgl: 690
            ),
            stormMotion: AnvilStormMotionDTO(
                status: stormMotionStatus,
                bunkersRight: AnvilBunkersRightStormMotionDTO(
                    uKt: 36.80394762849837,
                    vKt: 13.53066796460426,
                    speedKt: 39.21236458834915,
                    directionTowardDeg: 69.81446460119884,
                    uMs: 18.933570033795217,
                    vMs: 6.960770950382875,
                    speedMs: 20.172565688288692
                )
            ),
            mucape: 362.1018454649957,
            mlcape: 191.7304143918497,
            mlcin: -221.93726424748172,
            mllclMetersAgl: 1179.4130766012365,
            effectiveSrh: 29.42420403684148,
            effectiveBulkShearMs: 30.134722226263612,
            scp: scp,
            stpCin: stpCin,
            stpFixed: stpFixed,
            ship: ship,
            quality: AnvilQualityDTO(
                profileLevelCount: profileLevelCount,
                warnings: warnings
            )
        )
    }
}
