import CoreGraphics
import Foundation
import Network
import UIKit

/// Cliente leve do protocolo RFB (VNC 3.8) sobre `Network.framework` (`NWConnection`)
/// para exibir a saída gráfica opcional da VM (`-vnc 127.0.0.1:5900`) e enviar eventos de ponteiro/teclado.
@MainActor
public final class VNCClientService: ObservableObject {
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var statusMessage: String = "Desconectado"
    @Published public private(set) var framebufferImage: UIImage?
    @Published public private(set) var framebufferSize: CGSize = CGSize(width: 800, height: 600)

    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private var rawFramebuffer: [UInt8] = []
    private var fbWidth: Int = 0
    private var fbHeight: Int = 0
    private var rxBuffer = Data()

    public init() {}

    public func connect(host: String = "127.0.0.1", port: UInt16 = 5900) {
        disconnect()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            statusMessage = "Porta VNC inválida: \(port)"
            return
        }

        statusMessage = "Conectando a \(host):\(port)..."
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.statusMessage = "Handshake RFB..."
                    self.startRFBSession(conn: conn)
                case .failed(let error):
                    self.isConnected = false
                    self.statusMessage = "Falha VNC: \(error.localizedDescription)"
                case .cancelled:
                    self.isConnected = false
                    self.statusMessage = "Desconectado"
                default:
                    break
                }
            }
        }
        conn.start(queue: DispatchQueue(label: "com.qemu.vnc.client"))
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
        isConnected = false
        rxBuffer.removeAll()
        statusMessage = "Desconectado"
    }

    public func sendPointerEvent(x: Int, y: Int, buttonMask: UInt8) {
        guard isConnected, let conn = connection else { return }
        var packet = Data(count: 6)
        packet[0] = 5 // PointerEvent
        packet[1] = buttonMask
        let cx = UInt16(clamping: max(0, x)).bigEndian
        let cy = UInt16(clamping: max(0, y)).bigEndian
        packet.replaceSubrange(2..<4, with: withUnsafeBytes(of: cx) { Data($0) })
        packet.replaceSubrange(4..<6, with: withUnsafeBytes(of: cy) { Data($0) })
        conn.send(content: packet, completion: .contentProcessed { _ in })
    }

    public func sendKeyEvent(keysym: UInt32, down: Bool) {
        guard isConnected, let conn = connection else { return }
        var packet = Data(count: 8)
        packet[0] = 4 // KeyEvent
        packet[1] = down ? 1 : 0
        let ks = keysym.bigEndian
        packet.replaceSubrange(4..<8, with: withUnsafeBytes(of: ks) { Data($0) })
        conn.send(content: packet, completion: .contentProcessed { _ in })
    }

    // MARK: - Loop RFB 3.8

    private func startRFBSession(conn: NWConnection) {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 1. Server ProtocolVersion (12 bytes: "RFB 003.008\n")
                let versionData = try await self.readExact(count: 12, from: conn)
                let versionStr = String(data: versionData, encoding: .ascii) ?? "RFB 003.008\n"
                try await self.send(Data("RFB 003.008\n".utf8), on: conn)

                // 2. Security Types
                if versionStr.contains("003.008") || versionStr.contains("003.007") {
                    let countByte = try await self.readExact(count: 1, from: conn)[0]
                    guard countByte > 0 else {
                        throw AppError.vncConnectionFailed("Servidor VNC recusou a conexão.")
                    }
                    let types = try await self.readExact(count: Int(countByte), from: conn)
                    // Seleciona tipo 1 (None) quando disponível no QEMU local
                    guard types.contains(1) else {
                        throw AppError.vncConnectionFailed("Autenticação VNC não suportada (habilite sem senha local no QEMU).")
                    }
                    try await self.send(Data([1]), on: conn)
                    let secResult = try await self.readUInt32(from: conn)
                    guard secResult == 0 else {
                        throw AppError.vncConnectionFailed("Handshake de segurança VNC falhou.")
                    }
                } else {
                    let secType = try await self.readUInt32(from: conn)
                    if secType != 1 {
                        throw AppError.vncConnectionFailed("RFB 3.3 com segurança \(secType) não suportada.")
                    }
                }

                // 3. ClientInit (shared = 1)
                try await self.send(Data([1]), on: conn)

                // 4. ServerInit: width(2), height(2), pixelFormat(16), nameLen(4), name
                let width = Int(try await self.readUInt16(from: conn))
                let height = Int(try await self.readUInt16(from: conn))
                _ = try await self.readExact(count: 16, from: conn)
                let nameLen = Int(try await self.readUInt32(from: conn))
                let nameData = nameLen > 0 ? try await self.readExact(count: nameLen, from: conn) : Data()
                let desktopName = String(data: nameData, encoding: .utf8) ?? "QEMU VNC"

                self.fbWidth = max(1, width)
                self.fbHeight = max(1, height)
                self.framebufferSize = CGSize(width: self.fbWidth, height: self.fbHeight)
                self.rawFramebuffer = [UInt8](repeating: 0, count: self.fbWidth * self.fbHeight * 4)

                // Solicita SetPixelFormat RGBA 32-bit little-endian e SetEncodings (Raw)
                try await self.sendPixelFormatAndEncodings(on: conn)

                self.isConnected = true
                self.statusMessage = "\(desktopName) (\(self.fbWidth)×\(self.fbHeight))"

                try await self.requestFramebufferUpdate(incremental: false, on: conn)

                // Loop principal de mensagens Server-to-Client
                while !Task.isCancelled {
                    let msgType = try await self.readExact(count: 1, from: conn)[0]
                    switch msgType {
                    case 0: // FramebufferUpdate
                        _ = try await self.readExact(count: 1, from: conn) // padding
                        let rectCount = Int(try await self.readUInt16(from: conn))
                        for _ in 0..<rectCount {
                            let rx = Int(try await self.readUInt16(from: conn))
                            let ry = Int(try await self.readUInt16(from: conn))
                            let rw = Int(try await self.readUInt16(from: conn))
                            let rh = Int(try await self.readUInt16(from: conn))
                            let encoding = Int32(bitPattern: try await self.readUInt32(from: conn))

                            if encoding == 0 { // Raw
                                let byteCount = rw * rh * 4
                                let pixels = try await self.readExact(count: byteCount, from: conn)
                                self.applyRawRect(x: rx, y: ry, w: rw, h: rh, pixels: pixels)
                            }
                        }
                        self.renderFramebufferImage()
                        try await self.requestFramebufferUpdate(incremental: true, on: conn)

                    case 1: // SetColourMapEntries
                        _ = try await self.readExact(count: 3, from: conn)
                        let n = Int(try await self.readUInt16(from: conn))
                        _ = try await self.readExact(count: n * 6, from: conn)

                    case 2: // Bell
                        break

                    case 3: // ServerCutText
                        _ = try await self.readExact(count: 3, from: conn)
                        let len = Int(try await self.readUInt32(from: conn))
                        if len > 0 {
                            _ = try await self.readExact(count: len, from: conn)
                        }

                    default:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.isConnected = false
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func sendPixelFormatAndEncodings(on conn: NWConnection) async throws {
        // SetPixelFormat (msg 0, 20 bytes) -> 32bpp, depth 24, little-endian, true-color
        var pf = Data(count: 20)
        pf[0] = 0
        pf[4] = 32  // bits-per-pixel
        pf[5] = 24  // depth
        pf[6] = 0   // big-endian flag = 0 (little-endian)
        pf[7] = 1   // true-color flag = 1
        // red-max=255, green-max=255, blue-max=255
        pf[8] = 0; pf[9] = 255
        pf[10] = 0; pf[11] = 255
        pf[12] = 0; pf[13] = 255
        pf[14] = 0  // red-shift
        pf[15] = 8  // green-shift
        pf[16] = 16 // blue-shift
        try await send(pf, on: conn)

        // SetEncodings (msg 2, 1 encoding: Raw = 0)
        var enc = Data(count: 8)
        enc[0] = 2
        enc[3] = 1
        try await send(enc, on: conn)
    }

    private func requestFramebufferUpdate(incremental: Bool, on conn: NWConnection) async throws {
        var req = Data(count: 10)
        req[0] = 3
        req[1] = incremental ? 1 : 0
        let w = UInt16(fbWidth).bigEndian
        let h = UInt16(fbHeight).bigEndian
        req.replaceSubrange(6..<8, with: withUnsafeBytes(of: w) { Data($0) })
        req.replaceSubrange(8..<10, with: withUnsafeBytes(of: h) { Data($0) })
        try await send(req, on: conn)
    }

    private func applyRawRect(x: Int, y: Int, w: Int, h: Int, pixels: Data) {
        guard w > 0, h > 0 else { return }
        pixels.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for row in 0..<h {
                let targetY = y + row
                guard targetY >= 0 && targetY < fbHeight else { continue }
                for col in 0..<w {
                    let targetX = x + col
                    guard targetX >= 0 && targetX < fbWidth else { continue }
                    let srcIdx = (row * w + col) * 4
                    let dstIdx = (targetY * fbWidth + targetX) * 4
                    rawFramebuffer[dstIdx] = src[srcIdx]
                    rawFramebuffer[dstIdx + 1] = src[srcIdx + 1]
                    rawFramebuffer[dstIdx + 2] = src[srcIdx + 2]
                    rawFramebuffer[dstIdx + 3] = 255
                }
            }
        }
    }

    private func renderFramebufferImage() {
        let bytesPerRow = fbWidth * 4
        let data = Data(rawFramebuffer)
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        if let cgImage = CGImage(
            width: fbWidth,
            height: fbHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) {
            self.framebufferImage = UIImage(cgImage: cgImage)
        }
    }

    private func send(_ data: Data, on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func readExact(count: Int, from conn: NWConnection) async throws -> Data {
        while rxBuffer.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(throwing: AppError.vncConnectionFailed("Conexão encerrada pelo servidor VNC."))
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
            if !chunk.isEmpty {
                rxBuffer.append(chunk)
            }
        }
        let result = rxBuffer.prefix(count)
        rxBuffer.removeFirst(count)
        return Data(result)
    }

    private func readUInt16(from conn: NWConnection) async throws -> UInt16 {
        let data = try await readExact(count: 2, from: conn)
        return data.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    }

    private func readUInt32(from conn: NWConnection) async throws -> UInt32 {
        let data = try await readExact(count: 4, from: conn)
        return data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}

