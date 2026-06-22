import Foundation

struct HrrrNomadsURLBuilder: Sendable {
    private let halfWidthDegrees: Double
    private let halfHeightDegrees: Double

    init(
        halfWidthDegrees: Double = 0.15,
        halfHeightDegrees: Double = 0.175
    ) {
        self.halfWidthDegrees = halfWidthDegrees
        self.halfHeightDegrees = halfHeightDegrees
    }

    func makeSourceMetadata(
        for candidate: HrrrRunCandidate,
        around centroid: StormSetupCentroid
    ) -> StormSetupSourceMetadata {
        let bbox = makeBoundingBox(around: centroid)
        return StormSetupSourceMetadata(
            model: candidate.model,
            product: candidate.product,
            domain: candidate.domain,
            runTime: candidate.runTime,
            forecastHour: candidate.forecastHour,
            validTime: candidate.validTime,
            fieldSetVersion: candidate.fieldSetVersion,
            bbox: bbox,
            nomadsURL: makeURL(for: candidate, bbox: bbox)
        )
    }

    func makeBoundingBox(around centroid: StormSetupCentroid) -> StormSetupHrrrBoundingBox {
        StormSetupHrrrBoundingBox(
            around: centroid,
            halfWidthDegrees: halfWidthDegrees,
            halfHeightDegrees: halfHeightDegrees
        )
    }

    func makeURL(for candidate: HrrrRunCandidate, bbox: StormSetupHrrrBoundingBox) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "nomads.ncep.noaa.gov"
        components.path = candidate.fieldSetVersion.nomadsFilterPath
        components.percentEncodedQuery = percentEncodedQuery(for: candidate, bbox: bbox)
        return components.url
    }

    private func percentEncodedQuery(
        for candidate: HrrrRunCandidate,
        bbox: StormSetupHrrrBoundingBox
    ) -> String {
        var items: [String] = [
            encodedQueryItem(name: "dir", value: candidate.directoryPath),
            encodedQueryItem(name: "file", value: candidate.fileName)
        ]

        items.append(contentsOf: fieldFlagItems(for: candidate))
        items.append(contentsOf: levelFlagItems(for: candidate))
        items.append(encodedQueryItem(name: "subregion", value: ""))
        items.append(encodedQueryItem(name: "leftlon", value: formattedCoordinate(bbox.leftlon)))
        items.append(encodedQueryItem(name: "rightlon", value: formattedCoordinate(bbox.rightlon)))
        items.append(encodedQueryItem(name: "toplat", value: formattedCoordinate(bbox.toplat)))
        items.append(encodedQueryItem(name: "bottomlat", value: formattedCoordinate(bbox.bottomlat)))

        return items.joined(separator: "&")
    }

    private func fieldFlagItems(for candidate: HrrrRunCandidate) -> [String] {
        candidate.fieldSetVersion.nomadsVariableFlags.map {
            encodedQueryItem(name: $0, value: "on")
        }
    }

    private func levelFlagItems(for candidate: HrrrRunCandidate) -> [String] {
        candidate.fieldSetVersion.nomadsLevelFlags.map {
            encodedQueryItem(name: $0, value: "on")
        }
    }

    private func encodedQueryItem(name: String, value: String) -> String {
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: queryValueAllowedCharacters) ?? value
        return "\(name)=\(encodedValue)"
    }

    private var queryValueAllowedCharacters: CharacterSet {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return allowed
    }

    private func formattedCoordinate(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
