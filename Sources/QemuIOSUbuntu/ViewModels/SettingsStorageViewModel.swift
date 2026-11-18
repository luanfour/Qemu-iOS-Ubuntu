import Foundation
import SwiftUI

/// Preferência de aparência do aplicativo.
public enum AppThemePreference: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Claro"
        case .dark: return "Escuro"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// ViewModel da aba "Configurações": tema, modo servidor em segundo plano, JIT e armazenamento.
@MainActor
public final class SettingsStorageViewModel: ObservableObject {
    @Published public private(set) var breakdown: StorageBreakdown = .empty
    @Published public var themePreference: AppThemePreference {
        didSet {
            UserDefaults.standard.set(themePreference.rawValue, forKey: "appThemePreference")
        }
    }

    private let storageService: StorageService

    public init(storageService: StorageService) {
        self.storageService = storageService
        let stored = UserDefaults.standard.string(forKey: "appThemePreference") ?? AppThemePreference.system.rawValue
        self.themePreference = AppThemePreference(rawValue: stored) ?? .system
        refreshStorage()
    }

    public func refreshStorage() {
        breakdown = storageService.computeStorageBreakdown()
    }

    public func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

