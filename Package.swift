// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.executable(name: "Folio", targets: ["Folio"]),
               .library(name: "NotesCore", targets: ["NotesCore"])],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
        .package(url: "https://github.com/swiftlang/swift-cmark.git", .upToNextMinor(from: "0.5.0")),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0")
    ],
    targets: [
        .target(name: "NotesCore", dependencies: [
            .product(name: "Yams", package: "Yams"),
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            .product(name: "SwiftSoup", package: "SwiftSoup")
        ]),
        .executableTarget(name: "Folio", dependencies: ["NotesCore"]),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore", "Folio"])
    ]
)
