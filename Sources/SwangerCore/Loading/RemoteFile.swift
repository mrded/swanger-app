import Foundation

/// Downloads specs, and the files they refer to, from web servers.
public enum RemoteFile {
  /// How long to wait for a server before giving up.
  static let timeout: TimeInterval = 30

  /// Whether `url` is on a web server, over HTTP or HTTPS.
  public static func isRemote(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
  }

  /// Downloads `url`, always asking the server rather than a cache, so a reload sees changes.
  ///
  /// Blocks the calling thread until the download ends. Loading runs on a ``LargeStack`` thread of
  /// its own, so nothing else waits on it.
  static func fetch(_ url: URL) throws(LoadError) -> Data {
    let request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    let outcome = Outcome()
    let done = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      outcome.result = result(data: data, response: response, error: error, url: url)
      done.signal()
    }
    task.resume()
    done.wait()
    // The semaphore orders the write in the handler before this read.
    return try outcome.result!.get()
  }

  private static func result(
    data: Data?, response: URLResponse?, error: Error?, url: URL
  ) -> Result<Data, LoadError> {
    if let error {
      return .failure(LoadError(file: url, reason: .unreadable(error.localizedDescription)))
    }
    if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
      let status = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
      return .failure(
        LoadError(
          file: url, reason: .unreadable("The server answered \(response.statusCode) (\(status))."))
      )
    }
    return .success(data ?? Data())
  }

  /// Carries the download's result from URLSession's queue to the waiting thread.
  private final class Outcome: @unchecked Sendable {
    var result: Result<Data, LoadError>?
  }
}
