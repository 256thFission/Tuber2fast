import Foundation
import Testing
@testable import TNModel

@Suite("TNModel identities")
struct IdentityTests {
    @Test("An identity encodes as its uppercase UUID string and refuses any other spelling")
    func canonicalSpelling() throws {
        let id = PageID()
        let data = try JSONEncoder().encode(id)
        #expect(String(data: data, encoding: .utf8) == "\"\(id.raw.uuidString)\"")
        let lower = "\"\(id.raw.uuidString.lowercased())\"".data(using: .utf8)!
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PageID.self, from: lower) }
    }
}
