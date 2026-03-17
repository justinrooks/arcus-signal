import Crypto
import Foundation

enum StableContentHasher {
    static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex<T: Encodable>(
        of value: T,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .iso8601
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dateEncodingStrategy
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(value)
        return sha256Hex(of: data)
    }

    static func weakETag<T: Encodable>(
        of value: T,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .iso8601
    ) throws -> String {
        #"W/"\#(try sha256Hex(of: value, dateEncodingStrategy: dateEncodingStrategy))""#
    }
}
