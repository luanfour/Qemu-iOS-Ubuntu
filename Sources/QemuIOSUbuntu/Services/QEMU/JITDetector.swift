import Foundation
import QEMUBridge
import UIKit

/// Estado da detecção de JIT, integração com StikDebug e disponibilidade da biblioteca QEMU embarcada.
public struct RuntimeCapabilities: Sendable {
    public let isJITEnabled: Bool
    public let isStikDebugInstalled: Bool
    public let isStikJITInstalled: Bool
    public let isLibQEMUARM64Linked: Bool
    public let isLibQEMUX86Linked: Bool
    public let localIPAddress: String
    public let runtimeBundleID: String

    public var isAnyEmbeddedQEMULinked: Bool {
        isLibQEMUARM64Linked || isLibQEMUX86Linked
    }

    public var hasOnDeviceJITEnabler: Bool {
        isStikDebugInstalled || isStikJITInstalled
    }

    public var accelerationSummary: String {
        if isJITEnabled {
            return "JIT Ativo (CS_DEBUGGED)"
        }
        return "TCI sem JIT (Modo UTM SE)"
    }
}

/// Utilitário para inspecionar capacidades do processo iOS em tempo de execução
/// e disparar ativação de JIT sob demanda via StikDebug (`stikdebug://enable-jit`).
public enum JITDetector {
    @MainActor
    public static func currentCapabilities() -> RuntimeCapabilities {
        let jit = qemu_bridge_is_jit_enabled()
        let arm64 = qemu_bridge_is_libqemu_available("aarch64")
        let x86 = qemu_bridge_is_libqemu_available("x86_64")

        var ip = "127.0.0.1"
        if let rawIP = qemu_bridge_copy_local_ip_address() {
            ip = String(cString: rawIP)
            free(rawIP)
        }

        let stikDebugURL = URL(string: "stikdebug://")!
        let stikJITURL = URL(string: "stikjit://")!
        let hasStikDebug = UIApplication.shared.canOpenURL(stikDebugURL)
        let hasStikJIT = UIApplication.shared.canOpenURL(stikJITURL)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.luanquaresma.qemu-ios-ubuntu"

        return RuntimeCapabilities(
            isJITEnabled: jit,
            isStikDebugInstalled: hasStikDebug,
            isStikJITInstalled: hasStikJIT,
            isLibQEMUARM64Linked: arm64,
            isLibQEMUX86Linked: x86,
            localIPAddress: ip,
            runtimeBundleID: bundleID
        )
    }

    /// Constrói a URL oficial do StikDebug/StikJIT usando o Bundle ID real em execução
    /// (compatível inclusive quando o `xtool` ou SideStore adiciona sufixo de Team ID).
    @MainActor
    public static func stikDebugEnableJITURL() -> URL? {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.luanquaresma.qemu-ios-ubuntu"
        let encodedBundle = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleID

        if let stikDebug = URL(string: "stikdebug://enable-jit?bundle-id=\(encodedBundle)"),
           UIApplication.shared.canOpenURL(URL(string: "stikdebug://")!) {
            return stikDebug
        }

        if let stikJIT = URL(string: "stikjit://enable-jit?bundle-id=\(encodedBundle)"),
           UIApplication.shared.canOpenURL(URL(string: "stikjit://")!) {
            return stikJIT
        }

        return URL(string: "stikdebug://enable-jit?bundle-id=\(encodedBundle)")
    }

    /// Abre o StikDebug para anexar o depurador ao processo atual e habilitar `CS_DEBUGGED`.
    @MainActor
    public static func requestJITViaStikDebug() {
        guard let url = stikDebugEnableJITURL() else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
