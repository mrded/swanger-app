// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "Swanger",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "SwangerCore", targets: ["SwangerCore"]),
    .library(name: "SwangerValidation", targets: ["SwangerValidation"]),
  ],
  dependencies: [
    .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    .package(url: "https://github.com/ajevans99/swift-json-schema.git", from: "0.14.2"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
  ],
  targets: [
    .target(
      name: "SwangerCore",
      dependencies: [
        .product(name: "Yams", package: "Yams"),
        .product(name: "JSONSchema", package: "swift-json-schema"),
        .product(name: "OrderedJSON", package: "swift-json-schema"),
        .product(name: "OrderedCollections", package: "swift-collections"),
      ]
    ),
    .target(
      name: "SwangerValidation",
      dependencies: [
        "SwangerCore",
        .product(name: "JSONSchema", package: "swift-json-schema"),
      ]
    ),
    .testTarget(
      name: "SwangerCoreTests",
      dependencies: [
        "SwangerCore",
        .product(name: "JSONSchema", package: "swift-json-schema"),
        .product(name: "OrderedJSON", package: "swift-json-schema"),
        .product(name: "OrderedCollections", package: "swift-collections"),
      ],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "SwangerValidationTests",
      dependencies: ["SwangerValidation"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
