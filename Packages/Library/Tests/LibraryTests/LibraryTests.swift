import Foundation
import Persistence
import Photos
import Testing
@testable import Library

private struct FakeResource: ResourceDescription, Equatable {
    let type: PHAssetResourceType
    var isCurrent = false
}

@Suite struct ResourceSelectionTests {
    @Test func singlePhotoIsUsed() {
        let photo = FakeResource(type: .photo)
        #expect(ResourceSelection.uploadResource(among: [photo, FakeResource(type: .pairedVideo)], mediaType: .image) == photo)
    }

    @Test func editedPhotoUsesTheCurrentRendering() {
        let original = FakeResource(type: .photo)
        let edit = FakeResource(type: .fullSizePhoto, isCurrent: true)
        let adjustments = FakeResource(type: .adjustmentData, isCurrent: true)
        #expect(ResourceSelection.uploadResource(among: [original, adjustments, edit], mediaType: .image) == edit)
    }

    @Test func withoutCurrentFlagFallsBackToFullSize() {
        let original = FakeResource(type: .photo)
        let full = FakeResource(type: .fullSizePhoto)
        #expect(ResourceSelection.uploadResource(among: [original, full], mediaType: .image) == full)
    }

    @Test func ambiguousResourcesAreNotGuessed() {
        // Same as the official app: two candidates, neither current nor full-size → nothing.
        let photo = FakeResource(type: .photo)
        let alternate = FakeResource(type: .alternatePhoto)
        #expect(ResourceSelection.uploadResource(among: [photo, alternate], mediaType: .image) == nil)
    }

    @Test func videosIgnorePhotoResources() {
        let video = FakeResource(type: .video)
        #expect(ResourceSelection.uploadResource(among: [FakeResource(type: .photo), video], mediaType: .video) == video)
        let edited = FakeResource(type: .fullSizeVideo)
        #expect(ResourceSelection.uploadResource(among: [video, edited], mediaType: .video) == edited)
    }

    @Test func livePhotoMotionPart() {
        let motion = FakeResource(type: .pairedVideo)
        #expect(ResourceSelection.motionResource(among: [FakeResource(type: .photo), motion]) == motion)
        let editedMotion = FakeResource(type: .fullSizePairedVideo, isCurrent: true)
        #expect(ResourceSelection.motionResource(among: [motion, editedMotion]) == editedMotion)
    }
}

@Suite struct ChecksumTests {
    @Test func matchesKnownSHA1Vectors() throws {
        var hasher = ChecksumHasher()
        hasher.update(Data("abc".utf8))
        // SHA-1("abc") = a9993e36 4706816a ba3e2571 7850c26c 9cd0d89d
        #expect(hasher.finalize() == Data([0xa9, 0x99, 0x3e, 0x36, 0x47, 0x06, 0x81, 0x6a, 0xba, 0x3e, 0x25, 0x71, 0x78, 0x50, 0xc2, 0x6c, 0x9c, 0xd0, 0xd8, 0x9d]).base64EncodedString())
        #expect(ChecksumHasher().finalize() == "2jmj7l5rSw0yVb/vlWAYkK/YBwk=") // empty input
    }

    @Test func streamingAFileEqualsHashingItWhole() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data((0..<3_500_000).map { UInt8(($0 * 31) % 256) })
        try data.write(to: url)
        var whole = ChecksumHasher()
        whole.update(data)
        #expect(try ChecksumHasher.checksum(ofFile: url) == whole.finalize())
    }
}

@Suite struct CloudIdMatchTests {
    private func candidate(created: Date?, adjusted: Date? = nil, remoteCreated: String?, remoteAdjusted: String? = nil) -> CloudIdCandidate {
        CloudIdCandidate(localID: "L", modifiedAt: nil, createdAt: created, adjustmentTime: adjusted,
                         remoteChecksum: "sum", remoteCreatedAt: remoteCreated, remoteAdjustmentTime: remoteAdjusted)
    }

    private let created = Date(timeIntervalSince1970: 1_761_150_489) // 2025-10-22T16:28:09Z

    @Test func sameCaptureTimeAndNoEditsMatch() {
        #expect(LocalLibrary.isSameVersion(candidate(created: created, remoteCreated: "2025-10-22T16:28:09.000Z")))
        #expect(LocalLibrary.isSameVersion(candidate(created: created, remoteCreated: "2025-10-22T16:28:09Z")))
    }

    @Test func editedSinceUploadDoesNotMatch() {
        let edit = Date(timeIntervalSince1970: 1_761_160_000)
        #expect(!LocalLibrary.isSameVersion(candidate(created: created, adjusted: edit, remoteCreated: "2025-10-22T16:28:09.000Z")))
        #expect(LocalLibrary.isSameVersion(candidate(created: created, adjusted: edit, remoteCreated: "2025-10-22T16:28:09.000Z",
                                                     remoteAdjusted: "2025-10-22T19:06:40.000Z")))
    }

    @Test func differentCaptureTimeDoesNotMatch() {
        #expect(!LocalLibrary.isSameVersion(candidate(created: created, remoteCreated: "2025-10-22T16:28:11.000Z")))
        #expect(!LocalLibrary.isSameVersion(candidate(created: created, remoteCreated: nil)))
    }

    @Test func readsOlderLocalTimeFormat() {
        // Older official-app versions wrote local time without an offset.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let text = formatter.string(from: created)
        #expect(LocalLibrary.parseDate(text) == created)
    }
}
