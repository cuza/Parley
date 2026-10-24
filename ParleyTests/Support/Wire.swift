import Foundation
import SwiftProtobuf

/// Protobuf wire bytes assembled by hand, to pin nesting that a proto built and parsed by the same schema can't catch.
enum Wire {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }
    static func int(_ field: Int, _ value: UInt64) -> [UInt8] { varint(UInt64(field << 3)) + varint(value) }
    static func ld(_ field: Int, _ bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }
    static func str(_ field: Int, _ text: String) -> [UInt8] { ld(field, Array(text.utf8)) }
    /// A fixture message's bytes. Fixtures are built from literals, so encoding them can't fail.
    static func encoded(_ message: some SwiftProtobuf.Message) -> Data {
        do { return try message.serializedData() } catch {
            preconditionFailure("A fixture proto didn't encode: \(error)")
        }
    }
}
