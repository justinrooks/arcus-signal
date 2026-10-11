@testable import App
import ArcusCore
import Foundation
import Testing

@Suite("SPC meso parser")
struct SPCMesoParserTests {
    private func fixture() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "meso", withExtension: "xml", subdirectory: "Fixtures/SPC"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func representativeFeed() throws {
        let data = Data(try fixture().utf8)
        let products = try SPCMesoParser.parse(data)
        #expect(products == (try SPCMesoParser.parse(data)))
        let md = try #require(products.first)
        #expect(products.count == 1)
        #expect(md.number == 123)
        #expect(md.productID == "SPC-MD-2025-123")
        #expect(md.validStart == date("2025-12-31T23:50:00Z"))
        #expect(md.validEnd == date("2026-01-01T02:00:00Z"))
        #expect(md.areasAffected == "Eastern Colorado\n   and western Kansas")
        #expect(md.summary.hasPrefix("Mesoscale Discussion 0123"))
        #expect(md.summary.contains("DISCUSSION...A representative discussion."))
        #expect(md.concerning == "Severe potential...Watch likely")
        #expect(md.watchProbability == 80)
        #expect(md.watchProbabilityText == "80")
        #expect(md.issueYear == 2025)
        #expect(md.threats?.peakWindMPH == 75)
        #expect(md.threats?.hailRangeInches == 2.5)
        #expect(md.threats?.tornadoStrength == "EF1-2 possible")
        #expect(md.coordinates.count == 4)
        #expect(md.coordinates.first == .init(latitude: 39, longitude: -102.88))
        #expect(md.coordinates.first == md.coordinates.last)
    }

    @Test(arguments: [("0288", -102.88), ("9950", -99.50), ("5999", -159.99), ("6000", -60.0)])
    func coordinateLongitudeEncoding(_ token: String, _ longitude: Double) throws {
        let xml = try fixture().replacingOccurrences(of: "39000288", with: "3900" + token)
        let md: MesoscaleDiscussionPayload = try #require(SPCMesoParser.parse(Data(xml.utf8)).first)
        #expect(md.coordinates.first == MesoscaleDiscussionCoordinate(latitude: 39, longitude: longitude))
        #expect(md.coordinates.last == md.coordinates.first)
    }

    @Test(arguments: [("Watch unlikely", "Unlikely"), ("Severe potential", "Unknown")])
    func sharedPayloadNonNumericWatchProbability(_ concern: String, _ label: String) throws {
        let xml = try fixture()
            .replacingOccurrences(of: "Probability of Watch Issuance...80 percent", with: "")
            .replacingOccurrences(of: "Severe potential...Watch likely", with: concern)
        let md = try #require(SPCMesoParser.parse(Data(xml.utf8)).first)
        #expect(md.watchProbability == nil)
        #expect(md.watchProbabilityText == label)
    }

    @Test func annualNumberReuse() throws {
        let original = try fixture()
        let nextYear = original.replacingOccurrences(of: "0550 PM CST Wed Dec 31 2025", with: "0550 PM CST Thu Dec 31 2026")
        let first = try #require(SPCMesoParser.parse(Data(original.utf8)).first)
        let second = try #require(SPCMesoParser.parse(Data(nextYear.utf8)).first)
        #expect(first.number == second.number)
        #expect(first.productID != second.productID)
        #expect(second.productID == "SPC-MD-2026-123")
    }

    @Test func daylightTimeIssuance() throws {
        let xml = try fixture()
            .replacingOccurrences(of: "0550 PM CST Wed Dec 31 2025", with: "0550 PM CDT Wed Jul 15 2026")
            .replacingOccurrences(of: "Valid 312350Z - 010200Z", with: "Valid 152250Z - 160200Z")
        let md = try #require(SPCMesoParser.parse(Data(xml.utf8)).first)
        #expect(md.issued == date("2026-07-15T22:50:00Z"))
        #expect(md.validStart == date("2026-07-15T22:50:00Z"))
        #expect(md.validEnd == date("2026-07-16T02:00:00Z"))
        #expect(md.productID == "SPC-MD-2026-123")
    }

    @Test func feedRefreshDoesNotChangeProductIdentity() throws {
        let afterMidnight = try fixture()
        let beforeMidnight = afterMidnight.replacingOccurrences(of: "Thu, 01 Jan 2026 00:05:00 GMT", with: "Wed, 31 Dec 2025 23:55:00 GMT")
        let first = try #require(SPCMesoParser.parse(Data(beforeMidnight.utf8)).first)
        let second = try #require(SPCMesoParser.parse(Data(afterMidnight.utf8)).first)
        #expect(first == second)
        #expect(second.issued == date("2025-12-31T23:50:00Z"))
        #expect(second.productID == "SPC-MD-2025-123")
    }

    @Test(arguments: [
        ("Concerning...Severe potential...Watch unlikely", "Unlikely"),
        ("Concerning...Tornado Watches 12 and 34", "Unlikely"),
        ("Concerning...Severe potential", "Unknown")
    ])
    func watchLabels(_ line: String, _ expected: String) {
        let result = MDTextParser.parseWatchFields(line)
        #expect(result.0 == expected)
        if line.contains("Watches") { #expect(result.1 == "Tornado Watch 12, 34") }
        #expect(MDTextParser.parseWatchFields(line + "\nProbability of Watch Issuance...999 percent").0 == "100")
    }

    @Test(arguments: [
        ("2026-03-01T00:05:00Z", "Valid 282350Z - 010200Z", "2026-02-28T23:50:00Z", "2026-03-01T02:00:00Z"),
        ("2024-02-29T23:50:00Z", "Valid 292350Z - 010200Z", "2024-02-29T23:50:00Z", "2024-03-01T02:00:00Z"),
        ("2025-12-31T23:50:00Z", "Valid 2350Z - 0200Z", "2025-12-31T23:50:00Z", "2026-01-01T02:00:00Z")
    ])
    func validityBoundaries(_ issued: String, _ text: String, _ start: String, _ end: String) throws {
        let pair = try #require(MDTextParser.parseValid(text, issued: date(issued)))
        #expect(pair.0 == date(start))
        #expect(pair.1 == date(end))
    }

    @Test(arguments: ["Valid 322350Z - 010200Z", "Valid 312460Z - 010200Z", "Valid 312350Z - 312350Z", "Valid 312350Z - 030200Z", "Valid 2350Z - 010200Z"])
    func invalidValidity(_ line: String) throws {
        let xml = try fixture().replacingOccurrences(of: "Valid 312350Z - 010200Z", with: line)
        #expect(throws: SPCMesoError.self) { try SPCMesoParser.parse(Data(xml.utf8)) }
    }

    @Test(arguments: ["39000288 40000200", "99999 99999999", "99000288 40000200 38500100", "39000288 40000200 3850010"])
    func malformedGeometry(_ block: String) throws {
        let xml = try fixture().replacingOccurrences(of: "39000288 40000200 38500100 39000288", with: block)
        #expect(throws: SPCMesoError.self) { try SPCMesoParser.parse(Data(xml.utf8)) }
    }

    @Test func wholeFeedRejectionAndEnvelope() throws {
        let valid = try fixture()
        let invalidItem = "<item><title>SPC MD 9999</title><description>bad</description></item>"
        #expect(throws: SPCMesoError.self) {
            try SPCMesoParser.parse(Data(valid.replacingOccurrences(of: "</channel>", with: invalidItem + "</channel>").utf8))
        }
        for xml in ["<rss/>", "<rss><channel>", "<other><channel/></other>"] {
            #expect(throws: SPCMesoError.self) { try SPCMesoParser.parse(Data(xml.utf8)) }
        }
        #expect(try SPCMesoParser.parse(Data("<rss><channel/></rss>".utf8)).isEmpty)
    }

    @Test func optionalGeometryAndTitleFallback() throws {
        let xml = try fixture().replacingOccurrences(of: "LAT...LON 39000288 40000200 38500100 39000288", with: "")
            .replacingOccurrences(of: "md0123.html", with: "discussion.html")
        let md = try #require(SPCMesoParser.parse(Data(xml.utf8)).first)
        #expect(md.number == 123)
        #expect(md.coordinates.isEmpty)
    }

    @Test func geometryClosureBreakMarkersAndThreatVariants() throws {
        let xml = try fixture().replacingOccurrences(of: "39000288 40000200 38500100 39000288", with: "39000288 99999 40000200\n38500100")
            .replacingOccurrences(of: "60-75 MPH", with: "60 KT")
            .replacingOccurrences(of: "1.00-2.50 IN", with: "UP TO 1.50 IN")
            .replacingOccurrences(of: "TORNADO INTENSITY", with: "TORNADO STRENGTH")
        let md = try #require(SPCMesoParser.parse(Data(xml.utf8)).first)
        #expect(md.coordinates.count == 4)
        #expect(md.coordinates.first == md.coordinates.last)
        // Preserve SkyAware's numeric KT behavior rather than invent a unit conversion.
        #expect(md.threats?.peakWindMPH == 60)
        #expect(md.threats?.hailRangeInches == 1.5)
        #expect(md.threats?.tornadoStrength == "EF1-2 possible")
    }

    @Test(arguments: [
        ("https://www.spc.noaa.gov/products/md/md0123.html", "file:///md0123.html"),
        ("Thu, 01 Jan 2026 00:05:00 GMT", "not a date"),
        ("0550 PM CST Wed Dec 31 2025", "not an issuance time"),
        ("Valid 312350Z - 010200Z", "no validity line")
    ])
    func malformedRequiredFields(_ original: String, _ replacement: String) throws {
        let xml = try fixture().replacingOccurrences(of: original, with: replacement)
        #expect(throws: SPCMesoError.self) { try SPCMesoParser.parse(Data(xml.utf8)) }
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}
