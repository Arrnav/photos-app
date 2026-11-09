import Core
import Foundation
import Testing
@testable import ImmichAPI

@Suite struct ServerAddressTests {
    @Test(arguments: [
        ("192.168.1.10:2283", "http://192.168.1.10:2283"),
        ("http://192.168.1.10:2283/", "http://192.168.1.10:2283"),
        ("http://100.64.0.10:2283/api", "http://100.64.0.10:2283"),
        (" https://photos.example.com/api/ ", "https://photos.example.com"),
    ])
    func normalizes(input: String, expected: String) {
        #expect(ServerAddresses.normalize(input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://host", "http://"])
    func rejects(input: String) {
        #expect(ServerAddresses.normalize(input) == nil)
    }

    @Test func apiURLAppendsApi() {
        #expect(ImmichClient.apiURL(for: URL(string: "http://192.168.1.10:2283")!).absoluteString == "http://192.168.1.10:2283/api")
    }

    @Test func mediaURLsFollowTheSpecPaths() {
        let server = URL(string: "http://h:2283")!
        #expect(MediaEndpoints.thumbnail(server: server, assetID: "abc", size: .thumbnail).absoluteString == "http://h:2283/api/assets/abc/thumbnail?size=thumbnail")
        #expect(MediaEndpoints.original(server: server, assetID: "abc").absoluteString == "http://h:2283/api/assets/abc/original")
        #expect(MediaEndpoints.videoPlayback(server: server, assetID: "abc").absoluteString == "http://h:2283/api/assets/abc/video/playback")
    }

    @Test func mediaRequestCarriesBearerToken() {
        let request = MediaEndpoints.request(URL(string: "http://h/x")!, token: "t0k")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
        #expect(request.value(forHTTPHeaderField: "deviceType") == "iOS")
    }
}

@Suite struct VersionCheckTests {
    @Test func classifiesVersions() {
        #expect(VersionCheck(server: ServerVersion(major: 3, minor: 3, patch: 5)) == .matches)
        #expect(VersionCheck(server: ServerVersion(major: 3, minor: 4, patch: 0)).warning?.contains("newer") == true)
        #expect(VersionCheck(server: ServerVersion(major: 3, minor: 3, patch: 4)).warning?.contains("older") == true)
        #expect(ServerVersion(major: 3, minor: 10, patch: 0) > ServerVersion(major: 3, minor: 9, patch: 9))
    }

    @Test func parsesImmichDates() {
        #expect(ImmichDateParser.parse("2024-01-01T00:00:00.000Z") != nil)
        #expect(ImmichDateParser.parse("2024-01-01T00:00:00Z") != nil)
        #expect(ImmichDateParser.parse("2024-01-01T02:00:00+02:00") == ImmichDateParser.parse("2024-01-01T00:00:00Z"))
        #expect(ImmichDateParser.parse("yesterday") == nil)
    }
}
