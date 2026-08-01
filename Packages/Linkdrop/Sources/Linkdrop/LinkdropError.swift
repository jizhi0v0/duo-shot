import Foundation

public enum LinkdropError: Error, Sendable, Equatable {
    case unauthorized
    case offline
    case timedOut
    /// The gate refused the file. Carries a sentence, not a code.
    case unsupported(String)
    case server(status: Int, message: String)
    case fileUnreadable(String)

    /// Deliberately a full sentence.
    ///
    /// This string is the one a user reads when an upload fails, and
    /// "NSURLErrorDomain Code=-1009" is the outcome this whole type exists to
    /// prevent. Anything that catches an error here and shows a code instead has
    /// thrown away the only work this file does.
    public var message: String {
        switch self {
        case .unauthorized:
            "The server rejected the token."
        case .offline:
            "No network connection."
        case .timedOut:
            "The upload timed out."
        case .unsupported(let reason):
            reason
        case .server(let status, let message):
            message.isEmpty ? "The server returned \(status)." : message
        case .fileUnreadable(let reason):
            reason
        }
    }

    /// Whether trying the same upload again could plausibly work.
    ///
    /// Drives whether a UI offers "retry": offering it for a rejected token or
    /// an unsupported format trains people to click it and watch it fail.
    public var isRetryable: Bool {
        switch self {
        case .offline, .timedOut: true
        case .server(let status, _): status >= 500 || status == 0
        case .unauthorized, .unsupported, .fileUnreadable: false
        }
    }

    /// Maps whatever URLSession threw onto something worth showing.
    public static func from(_ error: any Error) -> LinkdropError {
        if let known = error as? LinkdropError { return known }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else {
            return .server(status: 0, message: ns.localizedDescription)
        }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return .offline
        case NSURLErrorTimedOut:
            return .timedOut
        default:
            return .server(status: 0, message: ns.localizedDescription)
        }
    }
}
