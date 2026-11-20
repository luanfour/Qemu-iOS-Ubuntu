// swift-tools-version: 5.9
// Manifesto SwiftPM compatível com xtool (xtool-org/xtool) para iOS 16+

import PackageDescription

let package = Package(
    name: "QemuIOSUbuntu",
    defaultLocalization: "pt-BR",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        // Produto de biblioteca principal consumido pelo xtool para gerar o .app iOS
        .library(
            name: "QemuIOSUbuntu",
            targets: ["QemuIOSUbuntu"]
        )
    ],
    dependencies: [
        // Emulador de terminal VT100/Xterm para console serial e SSH
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.5.1"),
        // Cliente SSH de alto nível construído sobre SwiftNIO SSH
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.0")
    ],
    targets: [
        // Ponte C para integração com libqemu pré-compilado (XCFramework) e verificação de JIT (csops)
        .target(
            name: "QEMUBridge",
            dependencies: [],
            path: "Sources/QEMUBridge",
            publicHeadersPath: "include",
            cSettings: [
                .define("QEMU_IOS_BRIDGE", to: "1")
            ]
        ),
        // Aplicação principal em SwiftUI
        .target(
            name: "QemuIOSUbuntu",
            dependencies: [
                "QEMUBridge",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Citadel", package: "Citadel")
            ],
            path: "Sources/QemuIOSUbuntu",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("BackgroundTasks"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("UIKit")
            ]
        ),
        // Testes unitários (lógica de modelos, QCOW2, comandos QEMU, validação ISO)
        .testTarget(
            name: "QemuIOSUbuntuTests",
            dependencies: ["QemuIOSUbuntu"],
            path: "Tests/QemuIOSUbuntuTests"
        )
    ]
)

