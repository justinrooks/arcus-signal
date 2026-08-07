@testable import App
import Foundation
import Testing

@Suite("Storm setup configuration", .serialized)
struct StormSetupConfigurationTests {
    @Test("resolved configuration uses local defaults when no environment overrides are present")
    func resolvedConfigurationUsesLocalDefaults() {
        let configuration = StormSetupConfiguration.resolved(
            from: [:],
            isExecutableFile: { _ in false }
        )

        #expect(configuration == .default)
        #expect(configuration.gribSubsetCacheRootURL == StormSetupConfiguration.localGribSubsetCacheRootURL)
        #expect(configuration.pressureGribSubsetCacheRootURL == StormSetupConfiguration.localPressureGribSubsetCacheRootURL)
        #expect(configuration.sampledSnapshotCacheRootURL == StormSetupConfiguration.localSampledSnapshotCacheRootURL)
        #expect(configuration.wgrib2ExecutableURL == StormSetupConfiguration.localWgrib2ExecutableURL)
        #expect(configuration.wgrib2TimeoutSeconds == 15)
        #expect(configuration.gribSubsetMaximumByteCount == 200 * 1024 * 1024)
        #expect(configuration.pressureArtifactProbeIntervalSeconds == 5 * 60)
        #expect(configuration.pressureArtifactMaxStaleAgeSeconds == 2 * 60 * 60)
        #expect(configuration.pressureArtifactDeleteGraceSeconds == 60 * 60)
        #expect(configuration.pressureArtifactCleanupIntervalSeconds == 15 * 60)
        #expect(configuration.pressureArtifactRecoveryTimeoutSeconds == 30 * 60)
        #expect(configuration.pressureArtifactWarmTimeoutSeconds == 15 * 60)
        #expect(configuration.pressureArtifactWarmTimeoutSeconds < configuration.pressureArtifactRecoveryTimeoutSeconds)
        #expect(configuration.pressureArtifactHTTPTimeoutSeconds == 30)
        #expect(configuration.anvilProfileAnalysisBaseURL == nil)
        #expect(configuration.anvilProfileAnalysisTimeoutSeconds == nil)
    }

    @Test("resolved configuration defaults to packaged wgrib2 when available")
    func resolvedConfigurationDefaultsToPackagedWgrib2WhenAvailable() {
        let configuration = StormSetupConfiguration.resolved(
            from: [:],
            isExecutableFile: { path in
                path == StormSetupConfiguration.packagedWgrib2ExecutableURL.path
            }
        )

        #expect(configuration.wgrib2ExecutableURL == StormSetupConfiguration.packagedWgrib2ExecutableURL)
        #expect(configuration.gribSubsetCacheRootURL == StormSetupConfiguration.localGribSubsetCacheRootURL)
        #expect(configuration.pressureGribSubsetCacheRootURL == StormSetupConfiguration.localPressureGribSubsetCacheRootURL)
        #expect(configuration.sampledSnapshotCacheRootURL == StormSetupConfiguration.localSampledSnapshotCacheRootURL)
    }

    @Test("resolved configuration honors Docker-friendly cache root and wgrib2 overrides")
    func resolvedConfigurationHonorsEnvironmentOverrides() {
        let configuration = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_CACHE_ROOT": "/app/storage/storm-setup",
            "STORM_SETUP_WGRIB2_PATH": "/usr/local/bin/wgrib2",
            "STORM_SETUP_WGRIB2_TIMEOUT_SECONDS": "21",
            "STORM_SETUP_GRIB_MAX_BYTES": "4194304",
            "STORM_SETUP_PRESSURE_ARTIFACT_PROBE_INTERVAL_SECONDS": "600",
            "STORM_SETUP_PRESSURE_ARTIFACT_MAX_STALE_AGE_SECONDS": "5400",
            "STORM_SETUP_PRESSURE_ARTIFACT_DELETE_GRACE_SECONDS": "1200",
            "STORM_SETUP_PRESSURE_ARTIFACT_CLEANUP_INTERVAL_SECONDS": "1800",
            "STORM_SETUP_PRESSURE_ARTIFACT_RECOVERY_TIMEOUT_SECONDS": "540",
            "STORM_SETUP_PRESSURE_ARTIFACT_WARM_TIMEOUT_SECONDS": "240",
            "STORM_SETUP_PRESSURE_ARTIFACT_HTTP_TIMEOUT_SECONDS": "42",
            "ANVIL_PROFILE_ANALYSIS_BASE_URL": "https://anvil.example.com",
            "ANVIL_PROFILE_ANALYSIS_TIMEOUT_SECONDS": "11"
        ])

        #expect(configuration.gribSubsetCacheRootURL.path == "/app/storage/storm-setup/grib-subsets")
        #expect(configuration.pressureGribSubsetCacheRootURL.path == "/app/storage/storm-setup/pressure-grib-subsets")
        #expect(configuration.sampledSnapshotCacheRootURL.path == "/app/storage/storm-setup/sampled-snapshots")
        #expect(configuration.wgrib2ExecutableURL.path == "/usr/local/bin/wgrib2")
        #expect(configuration.wgrib2TimeoutSeconds == 21)
        #expect(configuration.gribSubsetMaximumByteCount == 4_194_304)
        #expect(configuration.pressureArtifactProbeIntervalSeconds == 600)
        #expect(configuration.pressureArtifactMaxStaleAgeSeconds == 5_400)
        #expect(configuration.pressureArtifactDeleteGraceSeconds == 1_200)
        #expect(configuration.pressureArtifactCleanupIntervalSeconds == 1_800)
        #expect(configuration.pressureArtifactRecoveryTimeoutSeconds == 540)
        #expect(configuration.pressureArtifactWarmTimeoutSeconds == 240)
        #expect(configuration.pressureArtifactHTTPTimeoutSeconds == 42)
        #expect(configuration.anvilProfileAnalysisBaseURL?.absoluteString == "https://anvil.example.com")
        #expect(configuration.anvilProfileAnalysisTimeoutSeconds == 11)
    }

    @Test("pressure artifact warm timeout uses a safe value below the recovery lease for invalid overrides")
    func pressureArtifactWarmTimeoutUsesSafeValueBelowRecoveryLeaseForInvalidOverrides() {
        let invalidValues = [
            "  ", "banana", "nan", "infinity", "0", "-1", "100", "101", "9223372037", "0.0000000001"
        ]
        let missing = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_RECOVERY_TIMEOUT_SECONDS": "100"
        ])

        #expect(missing.pressureArtifactWarmTimeoutSeconds == 50)
        for value in invalidValues {
            let configuration = StormSetupConfiguration.resolved(from: [
                "STORM_SETUP_PRESSURE_ARTIFACT_RECOVERY_TIMEOUT_SECONDS": "100",
                "STORM_SETUP_PRESSURE_ARTIFACT_WARM_TIMEOUT_SECONDS": value
            ])
            #expect(configuration.pressureArtifactWarmTimeoutSeconds == 50)
            #expect(configuration.pressureArtifactWarmTimeoutSeconds > 0)
            #expect(configuration.pressureArtifactWarmTimeoutSeconds < configuration.pressureArtifactRecoveryTimeoutSeconds)
        }
    }

    @Test("recovery timeout clamps invalid or subsecond overrides to one second")
    func recoveryTimeoutClampsInvalidOrSubsecondOverridesToOneSecond() {
        let zero = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_RECOVERY_TIMEOUT_SECONDS": "0"
        ])
        let negative = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_RECOVERY_TIMEOUT_SECONDS": "-60"
        ])
        let invalid = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_RECOVERY_TIMEOUT_SECONDS": "banana"
        ])
        let fractional = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_RECOVERY_TIMEOUT_SECONDS": "0.5"
        ])
        let nanoseconds = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_RECOVERY_TIMEOUT_SECONDS": "0.000000002"
        ])

        #expect(zero.pressureArtifactRecoveryTimeoutSeconds == 1)
        #expect(negative.pressureArtifactRecoveryTimeoutSeconds == 1)
        #expect(invalid.pressureArtifactRecoveryTimeoutSeconds == 1)
        #expect(fractional.pressureArtifactRecoveryTimeoutSeconds == 1)
        #expect(nanoseconds.pressureArtifactRecoveryTimeoutSeconds == 1)
        #expect(nanoseconds.pressureArtifactWarmTimeoutSeconds == 0.5)
        #expect(
            nanoseconds.pressureArtifactWarmTimeoutSeconds
                < nanoseconds.pressureArtifactRecoveryTimeoutSeconds)
    }

    @Test("pressure artifact HTTP timeout defaults for missing, blank, malformed, zero, and negative overrides")
    func pressureArtifactHTTPTimeoutDefaultsForInvalidOverrides() {
        let missing = StormSetupConfiguration.resolved(from: [:])
        let blank = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_HTTP_TIMEOUT_SECONDS": "  "
        ])
        let malformed = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_HTTP_TIMEOUT_SECONDS": "banana"
        ])
        let zero = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_HTTP_TIMEOUT_SECONDS": "0"
        ])
        let negative = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_HTTP_TIMEOUT_SECONDS": "-1"
        ])
        let infinity = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_HTTP_TIMEOUT_SECONDS": "infinity"
        ])
        let exponentOverflow = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_HTTP_TIMEOUT_SECONDS": "1e309"
        ])
        let nanosecondOverflow = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_HTTP_TIMEOUT_SECONDS": "9223372037"
        ])
        let subnanosecond = StormSetupConfiguration.resolved(from: [
            "STORM_SETUP_PRESSURE_ARTIFACT_HTTP_TIMEOUT_SECONDS": "0.0000000001"
        ])

        #expect(missing.pressureArtifactHTTPTimeoutSeconds == 30)
        #expect(blank.pressureArtifactHTTPTimeoutSeconds == 30)
        #expect(malformed.pressureArtifactHTTPTimeoutSeconds == 30)
        #expect(zero.pressureArtifactHTTPTimeoutSeconds == 30)
        #expect(negative.pressureArtifactHTTPTimeoutSeconds == 30)
        #expect(infinity.pressureArtifactHTTPTimeoutSeconds == 30)
        #expect(exponentOverflow.pressureArtifactHTTPTimeoutSeconds == 30)
        #expect(nanosecondOverflow.pressureArtifactHTTPTimeoutSeconds == 30)
        #expect(subnanosecond.pressureArtifactHTTPTimeoutSeconds == 30)
    }
}
