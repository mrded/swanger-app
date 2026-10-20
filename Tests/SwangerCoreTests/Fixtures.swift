import Foundation
import OrderedJSON

enum Fixtures {
  /// The URL of a file under `Fixtures/`, such as `loading/petstore.yaml`.
  static func url(_ path: String) -> URL {
    Bundle.module.resourceURL!.appending(path: "Fixtures").appending(path: path)
  }
}

/// Every object key in `value` as a JSON Pointer, in the order they're visited, so that two
/// trees with the same keys in a different order compare unequal.
func keyPaths(_ value: JSONValue, at path: String = "") -> [String] {
  switch value {
  case .object(let object):
    object.flatMap { key, child in
      let childPath = "\(path)/\(key)"
      return [childPath] + keyPaths(child, at: childPath)
    }
  case .array(let array):
    array.enumerated().flatMap { index, child in keyPaths(child, at: "\(path)/\(index)") }
  default:
    []
  }
}
