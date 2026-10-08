import Tailcat
import Testing

@Suite struct DuplicateRegionTests {
    @Test func duplicateRegionIDsThrow() throws {
        let region = try Tailcat.DERPRegion(fields: ["RegionID": .integer(1)])
        #expect(throws: Tailcat.Failure.invalidInput("duplicate DERP region ID")) {
            try Tailcat.DERPMap(regions: [region, region])
        }
    }
}
