// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Worktime", platforms: [.macOS(.v14)], products: [.executable(name: "Worktime", targets: ["Worktime"])], targets: [.executableTarget(name: "Worktime", path: "Sources/Worktime")])
