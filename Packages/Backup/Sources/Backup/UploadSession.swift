import Core
import Foundation

/// Sends upload bodies (so tests can replace the background session).
public protocol UploadSession: Sendable {
    /// Starts sending `bodyFile`; `description` identifies the queue row after a relaunch.
    func start(_ request: URLRequest, bodyFile: URL, description: String) async -> Int
    /// Descriptions of uploads the system is still running (they survive app termination).
    func activeDescriptions() async -> Set<String>
    func cancelAll() async
}

/// What the background session reports back.
public enum UploadEvent: Sendable {
    case progress(description: String, sent: Int64, total: Int64)
    case finished(description: String, statusCode: Int?, body: Data, error: (any Error)?)
}

/// A background `URLSession`: uploads keep going while the app is suspended and even
/// after the system terminates it; iOS relaunches the app to deliver the results.
public final class BackgroundUploadSession: NSObject, UploadSession, URLSessionDataDelegate, @unchecked Sendable {
    public let identifier: String
    private let lock = NSLock()
    private var session: URLSession!
    private var bodies: [Int: Data] = [:]
    private var onEvent: (@Sendable (UploadEvent) -> Void)?
    private var finishEventsHandler: (() -> Void)?

    public init(identifier: String) {
        self.identifier = identifier
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // Gentle on the Pi (PLAN.md §6): two uploads at a time.
        configuration.httpMaximumConnectionsPerHost = 2
        // After a big video's last byte, the Pi may take minutes to store and answer.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func setEventHandler(_ handler: @escaping @Sendable (UploadEvent) -> Void) {
        lock.withLock { onEvent = handler }
    }

    /// iOS relaunched the app for this session's events; call `handler` once they're processed.
    public func setFinishEventsHandler(_ handler: @escaping () -> Void) {
        lock.withLock { finishEventsHandler = handler }
    }

    public func start(_ request: URLRequest, bodyFile: URL, description: String) async -> Int {
        let task = session.uploadTask(with: request, fromFile: bodyFile)
        task.taskDescription = description
        task.resume()
        return task.taskIdentifier
    }

    public func activeDescriptions() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
    }

    public func cancelAll() async {
        for task in await session.allTasks { task.cancel() }
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let description = task.taskDescription else { return }
        let handler = lock.withLock { onEvent }
        handler?(.progress(description: description, sent: totalBytesSent, total: totalBytesExpectedToSend))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (body, handler) = lock.withLock { (bodies.removeValue(forKey: task.taskIdentifier) ?? Data(), onEvent) }
        guard let description = task.taskDescription else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        handler?(.finished(description: description, statusCode: status, body: body, error: error))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (() -> Void)? in
            defer { finishEventsHandler = nil }
            return finishEventsHandler
        }
        // Give the queue a moment to record results before iOS suspends the app again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { handler?() }
    }
}
