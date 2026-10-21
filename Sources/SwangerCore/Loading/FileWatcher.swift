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
  /// What's known about a file, to tell real changes from folder noise. For a symbolic link, it
  /// covers both the link and the file it points to.
  private struct Fingerprint: Equatable {
    struct Item: Equatable {
      var fileNumber: Int?
      var size: Int?
      var modified: Date?

      /// Reads the item itself, not what it points to.
      init(_ path: String) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.intValue
        size = (attributes?[.size] as? NSNumber)?.intValue
        modified = attributes?[.modificationDate] as? Date
      }
    }

    var link: Item?
    var file: Item

    init(_ url: URL) {
      let target = url.resolvingSymlinksInPath()
      link = target == url ? nil : Item(url.path)
      file = Item(target.path)
    }

    var modified: Date? { [link?.modified, file.modified].compactMap(\.self).max() }
  }

  public let urls: [URL]
  private let latency: DispatchTimeInterval
  private let onChange: @Sendable () -> Void
  /// Guards everything below. Event handlers and debouncing run on it.
  private let queue = DispatchQueue(label: "Swanger.FileWatcher")
  /// Each watched path's source, with the file it was opened on.
  private var watches: [String: Watch] = [:]
  private var fingerprints: [Fingerprint]
  private var pending: DispatchWorkItem?
  private var isCancelled = false
  /// Calls back on the first settle whatever the fingerprints say: a file changed after
  /// `changedSince` but before the watcher started.
  private var changedBeforeStart = false

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
      // A file changed before its source was open sends no event, so look again now they are.
      let current = unique.map(Fingerprint.init)
      if current != fingerprints {
        eventArrived()
      } else if let changedSince,
        unique.indices.contains(where: { index in
          // A file deleted since leaves no date of its own, but its folder's changes.
          let changed = current[index].modified ?? Self.folderModified(above: unique[index])
          return changed ?? .distantPast >= changedSince
        })
      {
        // The fingerprints were taken after the change, so settling wouldn't see one.
        changedBeforeStart = true
        eventArrived()
      }
    }
  }

  deinit {
    for watch in watches.values { watch.source.cancel() }
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
  /// watched through the nearest folder above it that exists, moving down as folders appear. A
  /// symbolic link is watched along with the file it points to now, and that file's folder, and
  /// so is the folder holding each link to a folder along the way, so repointing it is seen.
  ///
  /// A path still on the same file keeps its source; only the rest are reopened, so a change
  /// doesn't need a second descriptor for every file while the old ones close.
  private func arm() {
    let targets = urls.map { $0.resolvingSymlinksInPath() }.filter { !urls.contains($0) }
    let files = urls + targets
    let folders =
      files.map { Self.nearestExistingFolder(above: $0) } + urls.flatMap(Self.linkFolders)
    var wanted: [URL] = []
    for url in files + folders where !wanted.contains(url) { wanted.append(url) }

    let identities = Dictionary(
      wanted.map { ($0.path, Self.identity(of: $0.path)) }, uniquingKeysWith: { first, _ in first })
    for (path, watch) in watches
    where identities[path] == nil || identities[path] != watch.file || watch.file == nil {
      watch.source.cancel()
      watches[path] = nil
    }

    for url in wanted where watches[url.path] == nil {
      let descriptor = open(url.path, O_EVTONLY)
      guard descriptor >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .extend, .attrib, .delete, .rename, .link, .revoke],
        queue: queue)
      source.setEventHandler { [weak self] in self?.eventArrived() }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      watches[url.path] = Watch(
        source: source, descriptor: descriptor, file: Self.identity(ofDescriptor: descriptor))
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

  /// When the nearest folder above `url` that exists last changed.
  private static func folderModified(above url: URL) -> Date? {
    let folder = nearestExistingFolder(above: url)
    let attributes = try? FileManager.default.attributesOfItem(atPath: folder.path)
    return attributes?[.modificationDate] as? Date
  }

  /// The folders holding each symbolic link met on the way to `url`, following chains of links
  /// one at a time: `schemas` and `shared` for `schemas/current/Pet.yaml` when `current` points
  /// at `shared/live`, itself a link. Repointing any of them changes its folder.
  private static func linkFolders(of url: URL) -> [URL] {
    /// As the kernel allows (`MAXSYMLINKS`), so a loop of links ends.
    let maximumLinks = 32
    var folders: [URL] = []
    var current = URL(filePath: "/")
    var remaining = Array(url.pathComponents.dropFirst())
    var links = 0
    while !remaining.isEmpty {
      let component = remaining.removeFirst()
      if component == "." { continue }
      if component == ".." {
        current = current.deletingLastPathComponent()
        continue
      }
      let next = current.appending(path: component)
      guard links < maximumLinks,
        let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: next.path)
      else {
        current = next
        continue
      }
      links += 1
      if !folders.contains(current) { folders.append(current) }
      var parts = (destination as NSString).pathComponents
      if parts.first == "/" {
        current = URL(filePath: "/")
        parts.removeFirst()
      }
      remaining = parts + remaining
    }
    return folders
  }

  private func disarm() {
    for watch in watches.values { watch.source.cancel() }
    watches = [:]
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
    // A file replaced or deleted keeps its old source watching nothing, so move to the new one.
    arm()
    let current = urls.map(Fingerprint.init)
    guard current != fingerprints || changedBeforeStart else { return }
    fingerprints = current
    changedBeforeStart = false
    onChange()
  }
}

extension FileWatcher {
  /// One open source.
  private struct Watch {
    let source: any DispatchSourceFileSystemObject
    let descriptor: Int32
    /// The device and inode the source watches.
    let file: FileIdentity?
  }

  struct FileIdentity: Equatable {
    let device: Int64
    let inode: UInt64
  }

  /// The file at `path` now, following symbolic links as `open` does.
  fileprivate static func identity(of path: String) -> FileIdentity? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
  }

  fileprivate static func identity(ofDescriptor descriptor: Int32) -> FileIdentity? {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { return nil }
    return FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
  }

  /// The descriptor open for each watched path, for tests.
  var descriptors: [String: Int32] {
    queue.sync { watches.mapValues(\.descriptor) }
  }
}
