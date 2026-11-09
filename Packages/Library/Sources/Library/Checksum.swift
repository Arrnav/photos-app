import CryptoKit
import Foundation
import Photos

/// SHA-1 encoded as base64: Immich's checksum format.
public struct ChecksumHasher: Sendable {
    private var hasher = Insecure.SHA1()

    public init() {}

    public mutating func update(_ data: Data) { hasher.update(data: data) }

    public func finalize() -> String { Data(hasher.finalize()).base64EncodedString() }

    /// Hashes a file in 1 MB chunks.
    public static func checksum(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = ChecksumHasher()
        while true {
            // Release each chunk straight away; a multi-GB video must not pile up in memory.
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        return hasher.finalize()
    }
}

public enum ChecksumError: Error, LocalizedError, Equatable {
    /// Only in iCloud ("Optimise iPhone Storage") and downloading wasn't allowed.
    case notOnPhone
    /// No resource matches the upload rule (`ResourceSelection`).
    case noUploadResource
    case assetGone
    case photoKit(String)

    public var errorDescription: String? {
        switch self {
        case .notOnPhone: "The original is only in iCloud."
        case .noUploadResource: "This item has no file that can be backed up."
        case .assetGone: "The item is no longer in the photo library."
        case .photoKit(let message): message
        }
    }
}

/// Streams a PhotoKit resource through SHA-1 without loading it into memory.
public enum ResourceHashing {
    public static func checksum(of resource: PHAssetResource, allowNetwork: Bool) async throws -> String {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        let box = HasherBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                    box.update(chunk)
                } completionHandler: { error in
                    if let error {
                        let nsError = error as NSError
                        // PHPhotosErrorNetworkAccessRequired: the original is in iCloud only.
                        if nsError.domain == PHPhotosErrorDomain, nsError.code == PHPhotosError.networkAccessRequired.rawValue {
                            continuation.resume(throwing: ChecksumError.notOnPhone)
                        } else if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: ChecksumError.photoKit(error.localizedDescription))
                        }
                    } else {
                        continuation.resume(returning: box.finalize())
                    }
                }
                box.requestID = id
            }
        } onCancel: {
            if let id = box.requestID { PHAssetResourceManager.default().cancelDataRequest(id) }
        }
    }
}

/// PhotoKit calls the data handler serially, but on its own queue.
private final class HasherBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = ChecksumHasher()
    private var _requestID: PHAssetResourceDataRequestID?

    var requestID: PHAssetResourceDataRequestID? {
        get { lock.withLock { _requestID } }
        set { lock.withLock { _requestID = newValue } }
    }

    func update(_ data: Data) { lock.withLock { hasher.update(data) } }
    func finalize() -> String { lock.withLock { hasher.finalize() } }
}
