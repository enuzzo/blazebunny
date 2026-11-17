// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Blazebunny",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BlazebunnyCore", targets: ["BlazebunnyCore"]),
        .executable(name: "Blazebunny", targets: ["Blazebunny"]),
        .executable(name: "bbbench", targets: ["bbbench"]),
        .executable(name: "bbscopebench", targets: ["bbscopebench"]),
    ],
    targets: [
        .target(name: "BlazebunnyCore"),
        .executableTarget(name: "Blazebunny", dependencies: ["BlazebunnyCore"]),
        .executableTarget(name: "bbbench", dependencies: ["BlazebunnyCore"]),
        .executableTarget(name: "bbscopebench", dependencies: ["BlazebunnyCore"]),
        .testTarget(name: "BlazebunnyCoreTests", dependencies: ["BlazebunnyCore"]),
    ]
)
