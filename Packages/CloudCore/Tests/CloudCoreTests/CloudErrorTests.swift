import CloudCore
import Foundation
import Testing

@Suite struct CloudErrorTests {
    @Test func describesNetworkFailures() {
        let error = CloudError.wrap(URLError(.timedOut), operation: "Sync")
        #expect(error.kind == .transport)
        #expect(error.message == "Sync: the server did not answer in time.")
        #expect(CloudError.wrap(error, operation: "Other") == error)
    }
}
