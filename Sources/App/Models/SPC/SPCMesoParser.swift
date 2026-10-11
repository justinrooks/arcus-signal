import ArcusCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum SPCMesoParser {
    static func parse(_ data: Data) throws -> [MesoscaleDiscussionPayload] {
        let reader = MesoRSSReader()
        let xml = XMLParser(data: data)
        xml.shouldResolveExternalEntities = false
        xml.delegate = reader
        guard xml.parse(), reader.hasChannel else { throw SPCMesoError.malformedFeed }
        return try reader.items.filter { ($0["title"] ?? "").contains("SPC MD ") }.map(makeDiscussion)
    }

    private static func makeDiscussion(_ item: [String: String]) throws -> MesoscaleDiscussionPayload {
        let title = item["title"] ?? ""
        guard let link = item["link"], let url = URL(string: link),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              let published = item["pubDate"], published.fromRFC822() != nil,
              let description = item["description"] else { throw SPCMesoError.malformedDiscussion(title) }
        let raw = preText(description)
        guard let issued = issueTime(raw),
              let valid = MDTextParser.parseValid(raw, issued: issued),
              let number = MDTextParser.parseMDNumber(from: url) ?? titleNumber(title)
        else { throw SPCMesoError.malformedDiscussion(title) }
        let watch = MDTextParser.parseWatchFields(raw)
        return MesoscaleDiscussionPayload(
            number: number, title: title, sourceURL: url, issued: issued,
            validStart: valid.0, validEnd: valid.1,
            areasAffected: MDTextParser.parseAreas(raw), summary: raw,
            concerning: watch.1,
            watchProbability: Double(watch.0), watchProbabilityText: watch.0,
            threats: MesoscaleDiscussionThreats(
                peakWindMPH: MDTextParser.parseWindMPH(raw),
                hailRangeInches: MDTextParser.parseHailRange(raw),
                tornadoStrength: MDTextParser.parseTornadoStrength(raw)
            ),
            coordinates: try polygon(raw, title: title)
        )
    }

    private static func issueTime(_ text: String) -> Date? {
        // RSS pubDate is the feed regeneration time, not the product issue time.
        guard let range = text.range(of: #"(?im)^\s*\d{4} [AP]M (?:CST|CDT) [A-Za-z]{3} [A-Za-z]{3} \d{1,2} \d{4}\s*$"#,
                                     options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).parseAsIssuedDate()
    }

    private static func titleNumber(_ title: String) -> Int? {
        guard let range = title.range(of: #"\b\d{3,4}\b"#, options: .regularExpression) else { return nil }
        return Int(title[range])
    }

    private static func preText(_ description: String) -> String {
        guard let start = description.range(of: "<pre>"),
              let end = description.range(of: "</pre>", range: start.upperBound..<description.endIndex)
        else { return description.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(description[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func polygon(_ text: String, title: String) throws -> [MesoscaleDiscussionCoordinate] {
        // Products without geometry remain readable, as in SkyAware. A present but
        // malformed block cannot silently become a partial polygon.
        guard let marker = text.range(of: "LAT...LON", options: .caseInsensitive) else { return [] }
        let tail = text[marker.upperBound...]
        let block = tail.prefix { $0.isNumber || $0.isWhitespace }
        var points: [MesoscaleDiscussionCoordinate] = []
        for token in block.split(whereSeparator: { $0.isWhitespace }) {
            if (5...8).contains(token.count), token.allSatisfy({ $0 == "9" }) { continue }
            guard token.count == 8, let lat = Double(token.prefix(4)), let lon = Double(token.suffix(4)) else {
                throw SPCMesoError.malformedDiscussion(title)
            }
            let latitude = lat / 100
            let longitude = lon / 100 < 60 ? -(100 + lon / 100) : -lon / 100
            guard (0...90).contains(latitude), (-180...0).contains(longitude) else {
                throw SPCMesoError.malformedDiscussion(title)
            }
            points.append(.init(latitude: latitude, longitude: longitude))
        }
        guard Set(points).count >= 3 else { throw SPCMesoError.malformedDiscussion(title) }
        if points.last != points.first, let first = points.first { points.append(first) }
        return points
    }
}

/// One reader per parse; no mutable state crosses tasks.
private final class MesoRSSReader: NSObject, XMLParserDelegate {
    var items: [[String: String]] = []
    var hasChannel = false
    private var stack: [String] = []
    private var item: [String: String]?
    private var field: String?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        stack.append(elementName)
        if stack == ["rss", "channel"] { hasChannel = true }
        if stack == ["rss", "channel", "item"] { item = [:] }
        if stack.count == 4, item != nil, ["title", "link", "pubDate", "description"].contains(elementName) {
            field = elementName
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if field != nil, let value = String(data: CDATABlock, encoding: .utf8) { text += value }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count == 4, field == elementName {
            item?[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            field = nil
        }
        if stack == ["rss", "channel", "item"], let item {
            items.append(item)
            self.item = nil
        }
        stack.removeLast()
    }
}
