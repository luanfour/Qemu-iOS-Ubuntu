import SwiftUI

/// Ponto de entrada principal da aplicação Qemu-ios-ubuntu (compatível com xtool + SwiftPM).
@main
public struct QemuIOSUbuntuApp: App {
    @StateObject private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(environment)
                .environmentObject(environment.qemuService)
                .environmentObject(environment.terminalService)
                .environmentObject(environment.sshService)
                .environmentObject(environment.backgroundService)
                .environmentObject(environment.vncService)
                .environmentObject(environment.vmManagerVM)
                .environmentObject(environment.terminalVM)
                .environmentObject(environment.sshVM)
                .environmentObject(environment.settingsVM)
                .preferredColorScheme(environment.settingsVM.themePreference.colorScheme)
                .task {
                    environment.backgroundService.registerBackgroundTasks()
                    await environment.backgroundService.requestNotificationPermission()
                    if environment.qemuService.autoRequestStikDebugOnLaunch,
                       !environment.qemuService.capabilities.isJITEnabled,
                       environment.qemuService.capabilities.hasOnDeviceJITEnabler {
                        environment.qemuService.requestJITWithStikDebug()
                    }
                }
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .background:
                        environment.backgroundService.handleAppDidEnterBackground()
                    case .active:
                        environment.backgroundService.handleAppWillEnterForeground()
                        environment.qemuService.refreshCapabilities()
                    default:
                        break
                    }
                }
        }
    }
}

