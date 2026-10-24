import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

struct ProbeTests {
    @Test func requestFieldNumbersMatchSchema() throws {
        #expect(Array(ProbeWire.identityRequest) == [0xA2, 0x06, 0x04, 0x08, 0x00, 0x10, 0x02])
        let fields = try ProbeWire.fields(ProbeWire.worldRequest(cursors: ["next"]))
        #expect(fields.map(\.number) == [1, 2, 5, 7])
        let section = try ProbeWire.fields(fields[1].bytes!)
        #expect(section.first?.integer == 200)
        #expect(section.last?.number == 6)
        #expect(section.last?.bytes == Data("next".utf8))
    }
    @Test func readsNestedIdentityAndSkipsUnknownFields() throws {
        let response =
            ProbeWire.message(1, ProbeWire.message(1, ProbeWire.string(1, "user-id"))) + ProbeWire.integer(123, 12345)
        #expect(try ProbeWire.identity(response) == "user-id")
    }
    @Test func readsSectionsAndDeduplicatesGroupIDs() throws {
        let room = ProbeWire.message(1, ProbeWire.message(1, ProbeWire.string(1, "space")))
        let dm = ProbeWire.message(1, ProbeWire.message(3, ProbeWire.string(1, "space")))
        let section =
            ProbeWire.message(2, room) + ProbeWire.message(2, dm) + ProbeWire.integer(5, 1)
            + ProbeWire.string(6, "next")
        let result = try ProbeWire.worldPage(ProbeWire.message(1, section) + ProbeWire.message(4, room))
        #expect(result.groupKeys == ["1:space", "3:space"])
        #expect(result.cursors == ["next"])
    }
    @Test func rejectsMalformedWireWithoutOverflows() {
        for bytes: [UInt8] in [[0], [0x80], [0x0A, 10, 1], Array(repeating: 0xFF, count: 10), [0x0B]] {
            #expect(throws: AuthFailure.malformedProto) { _ = try ProbeWire.fields(Data(bytes)) }
        }
        #expect(throws: AuthFailure.malformedProto) { _ = try ProbeWire.identity(Data()) }
    }
    @Test func rejectsMissingPaginationToken() {
        #expect(throws: AuthFailure.malformedProto) {
            _ = try ProbeWire.worldPage(ProbeWire.message(1, ProbeWire.integer(5, 1)))
        }
    }
    @Test func handlesBase64AndRejectsHTML() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://chat.google.com/api/x")!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/x-protobuf", "X-Goog-Safety-Encoding": "base64"])!
        #expect(
            try DynamiteReadProbe.responseBytes(Data([1, 2, 3]).base64EncodedData(), response: response)
                == Data([1, 2, 3]))
        let prefixed = Data([0x29, 0x5D, 0x7D, 0x27, 10]) + Data([1, 2, 3]).base64EncodedData()
        #expect(try DynamiteReadProbe.responseBytes(prefixed, response: response) == Data([1, 2, 3]))
        #expect(throws: AuthFailure.unexpectedResponse) {
            _ = try DynamiteReadProbe.responseBytes(Data("!!!".utf8), response: response)
        }
        let html = HTTPURLResponse(
            url: response.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        #expect(throws: AuthFailure.unexpectedResponse) {
            _ = try DynamiteReadProbe.responseBytes(Data("login".utf8), response: html)
        }
    }
}
