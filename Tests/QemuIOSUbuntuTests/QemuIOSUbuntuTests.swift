import Foundation
import XCTest
@testable import QemuIOSUbuntu

final class QemuIOSUbuntuTests: XCTestCase {
    func testQCOW2CreationProducesValidHeader() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).qcow2")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try QCOW2ImageBuilder.createEmptyQCOW2(at: tempURL, sizeGB: 16)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertTrue(QCOW2ImageBuilder.isValidQCOW2(at: tempURL))
    }

    func testQEMUCommandBuilderIncludesNATAndSerial() {
        let vm = VirtualMachine(
            name: "Ubuntu Test",
            architecture: .aarch64,
            cpuCores: 2,
            ramMB: 1024,
            diskSizeGB: 16,
            portForwards: [PortForwardRule(name: "SSH", transport: .tcp, hostPort: 2222, guestPort: 22)]
        )

        let args = vm.buildQEMUArguments(
            diskPath: "/tmp/disk.qcow2",
            isoPath: "/tmp/ubuntu.iso",
            qmpSocketPath: "/tmp/vm.qmp",
            serialPort: 4401,
            useJIT: false
        )

        XCTAssertEqual(args.first, "qemu-system-aarch64")
        XCTAssertTrue(args.contains(where: { $0.contains("hostfwd=tcp::2222-:22") }))
        XCTAssertTrue(args.contains("tcp:127.0.0.1:4401,server=on,wait=off"))
    }
}
