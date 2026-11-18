import SwiftUI

/// Abas principais da interface do aplicativo.
public enum AppTab: Hashable {
    case machines
    case terminal
    case ssh
    case settings
}

/// Container raiz com `TabView` moderno contendo as 4 abas solicitadas:
/// "Máquinas", "Terminal", "SSH" e "Configurações".
public struct MainTabView: View {
    @State private var selectedTab: AppTab = .machines
    @EnvironmentObject private var vmManagerVM: VMManagerViewModel
    @EnvironmentObject private var terminalVM: TerminalViewModel
    @EnvironmentObject private var sshVM: SSHViewModel

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            MachinesListView(
                onOpenSerialTerminal: { vm in
                    terminalVM.selectedVMId = vm.id
                    selectedTab = .terminal
                },
                onOpenQuickSSH: { vm in
                    sshVM.quickConnectToVM(vm)
                    selectedTab = .ssh
                }
            )
            .tabItem {
                Label("Máquinas", systemImage: "server.rack")
            }
            .tag(AppTab.machines)

            TerminalTabView()
                .tabItem {
                    Label("Terminal", systemImage: "terminal")
                }
                .tag(AppTab.terminal)

            SSHTabView()
                .tabItem {
                    Label("SSH", systemImage: "network")
                }
                .tag(AppTab.ssh)

            SettingsTabView()
                .tabItem {
                    Label("Configurações", systemImage: "gearshape.2")
                }
                .tag(AppTab.settings)
        }
        .alert(
            "Aviso",
            isPresented: Binding(
                get: { vmManagerVM.activeErrorMessage != nil },
                set: { if !$0 { vmManagerVM.activeErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                vmManagerVM.activeErrorMessage = nil
            }
        } message: {
            Text(vmManagerVM.activeErrorMessage ?? "")
        }
    }
}

