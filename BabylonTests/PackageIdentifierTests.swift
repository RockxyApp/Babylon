import Foundation
import Testing
@testable import Babylon

struct PackageIdentifierTests {
    @Test("Same object returns the same identifier on repeated calls")
    func sameObjectReturnsSameID() {
        let object = NSObject()
        let firstID = PackageIdentifier.getID(for: object)
        let secondID = PackageIdentifier.getID(for: object)
        let thirdID = PackageIdentifier.getID(for: object)

        #expect(firstID == secondID)
        #expect(secondID == thirdID)
    }

    @Test("Different objects return different identifiers")
    func differentObjectsReturnDifferentIDs() {
        let objectA = NSObject()
        let objectB = NSObject()

        let idA = PackageIdentifier.getID(for: objectA)
        let idB = PackageIdentifier.getID(for: objectB)

        #expect(idA != idB)
    }

    @Test("Returned identifier is a valid UUID string")
    func idIsValidUUID() {
        let object = NSObject()
        let id = PackageIdentifier.getID(for: object)

        let parsed = UUID(uuidString: id)
        #expect(parsed != nil, "Expected a valid UUID string but got: \(id)")
    }
}
