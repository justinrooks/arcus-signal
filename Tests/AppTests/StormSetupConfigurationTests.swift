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
        #expect(configuration.anvilProfileAnalysisBaseURL?.absoluteString == "https://anvil.example.com")
        #expect(configuration.anvilProfileAnalysisTimeoutSeconds == 11)
    }
}
