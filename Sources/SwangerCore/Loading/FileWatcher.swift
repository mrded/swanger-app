import Dispatch
import Foundation

/// Calls back when any of a set of files changes, such as a spec and the files it refers to.
///
/// Each file is watched with a `DispatchSource`, and so is the folder it's in, so that a file
/// replaced by an atomic save, deleted, or created after being missing is noticed too. Events are
/// debounced: the callback runs once `latency` after the last of a burst, and only when a file's
/// size, modification date or identity has really changed, so other files coming and going in the
/// same folders don't count.
public final class FileWatcher: @unchecked Sendable {
  /// What's known about a file, to tell real changes from folder noise.
  private struct Fingerprint: Equatable {
    var fileNumber: Int?
    var size: Int?
    var modified: Date?

    /// Nothing known, so any file differs from it.
    init() {}

    init(_ url: URL) {
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.intValue
      size = (attributes?[.size] as? NSNumber)?.intValue
      modified = attributes?[.modificationDate] as? Date
    }
  }

  public let urls: [URL]
  private let latency: DispatchTimeInterval
  private let onChange: @Sendable () -> Void
  /// Guards everything below. Event handlers and debouncing run on it.
  private let queue = DispatchQueue(label: "Swanger.FileWatcher")
  private var sources: [any DispatchSourceFileSystemObject] = []
  private var fingerprints: [Fingerprint]
  private var pending: DispatchWorkItem?
  private var isCancelled = false

  /// Starts watching `urls`. Files that don't exist yet are watched for being created.
  ///
  /// - Parameters:
  ///   - changedSince: When the files were read, if before now. A file modified since then calls
  ///     back straight away, so an edit made while they were being loaded isn't missed.
  ///   - onChange: Called on a background queue.
  public init(
    urls: [URL],
    changedSince: Date? = nil,
    latency: DispatchTimeInterval = .milliseconds(300),
    onChange: @escaping @Sendable () -> Void
  ) {
    var unique: [URL] = []
    for url in urls.map(\.standardizedFileURL) where !unique.contains(url) { unique.append(url) }
    self.urls = unique
    self.latency = latency
    self.onChange = onChange
    fingerprints = unique.map(Fingerprint.init)
    queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
    queue.sync {
      arm()
      if let changedSince,
        fingerprints.contains(where: { $0.modified ?? .distantPast >= changedSince })
      {
        // Settling compares with the fingerprints, so forget the ones taken after the change.
        fingerprints = unique.map { _ in Fingerprint() }
        eventArrived()
      }
    }
  }

  deinit {
    for source in sources { source.cancel() }
    pending?.cancel()
  }

  /// Stops watching. The callback isn't called again. It can be called from the callback.
  public func cancel() {
    let stop = {
      self.isCancelled = true
      self.pending?.cancel()
      self.disarm()
    }
    if DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self) {
      stop()
    } else {
      queue.sync(execute: stop)
    }
  }

  /// Marks ``queue``, so ``cancel()`` can tell when it's already running on it.
  private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

  /// Opens a source for each file and folder that exists now. A file whose folder is missing is
  /// watched through the nearest folder above it that exists, moving down as folders appear.
  private func arm() {
    let folders = urls.map { Self.nearestExistingFolder(above: $0) }
    var watched: [URL] = []
    for url in urls + folders where !watched.contains(url) {
      watched.append(url)
      let descriptor = open(url.path, O_EVTONLY)
      guard descriptor >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .extend, .attrib, .delete, .rename, .link, .revoke],
        queue: queue)
      source.setEventHandler { [weak self] in self?.eventArrived() }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      sources.append(source)
    }
  }

  private static func nearestExistingFolder(above url: URL) -> URL {
    var folder = url.deletingLastPathComponent()
    var isFolder: ObjCBool = false
    while !(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder)
      && isFolder.boolValue) && folder.path != "/"
    {
      folder = folder.deletingLastPathComponent()
    }
    return folder
  }

  private func disarm() {
    for source in sources { source.cancel() }
    sources = []
  }

  private func eventArrived() {
    guard !isCancelled else { return }
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.settle() }
    pending = work
    queue.asyncAfter(deadline: .now() + latency, execute: work)
  }

  /// Runs once a burst of events is over.
  private func settle() {
    guard !isCancelled else { return }
    // A file replaced or deleted keeps its old source watching nothing, so start again.
    disarm()
    arm()
    let current = urls.map(Fingerprint.init)
    guard current != fingerprints else { return }
    fingerprints = current
    onChange()
  }
}
