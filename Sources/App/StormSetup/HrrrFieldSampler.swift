import Foundation

struct HrrrFieldSample: Sendable, Codable, Equatable {
    let requestedLongitude: Double
    let requestedLatitude: Double
    let point: Wgrib2PointSample
}

struct HrrrFieldSampler: Sendable {
    let client: any Wgrib2Sampling
    let matchPattern: String?

    init(
        client: any Wgrib2Sampling,
        matchPattern: String? = nil
    ) {
        self.client = client
        self.matchPattern = matchPattern
    }

    func sample(
        from subset: GribSubsetCacheResult,
        around centroid: StormSetupCentroid
    ) async throws -> [HrrrFieldSample] {
        try await sample(localFileURL: subset.localFileURL, around: centroid)
    }

    func sample(
        localFileURL: URL,
        around centroid: StormSetupCentroid
    ) async throws -> [HrrrFieldSample] {
        let pointSamples = try await client.samplePoint(
            Wgrib2PointRequest(
                fileURL: localFileURL,
                longitude: centroid.longitude,
                latitude: centroid.latitude,
                matchPattern: matchPattern
            )
        )

        return pointSamples.map { point in
            HrrrFieldSample(
                requestedLongitude: centroid.longitude,
                requestedLatitude: centroid.latitude,
                point: point
            )
        }
    }
}
