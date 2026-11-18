import SwiftUI

/// Aba "SSH": cliente SSH completo com hosts salvos, acesso rápido às VMs locais,
/// gerenciador de chaves e abas múltiplas com `SwiftTerm` + `Citadel`.
public struct SSHTabView: View {
    @EnvironmentObject private var sshService: SSHService
    @EnvironmentObject private var sshVM: SSHViewModel
    @EnvironmentObject private var vmManagerVM: VMManagerViewModel
    @EnvironmentObject private var qemuService: QEMUService

    @State private var isShowingHostsDrawer = false

    public init() {}

    private var selectedTab: SSHSessionTab? {
        if let id = sshService.selectedTabId,
           let found = sshService.tabs.first(where: { $0.id == id }) {
            return found
        }
        return sshService.tabs.first
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !sshService.tabs.isEmpty {
                    tabsStripBar
                }

                if let activeTab = selectedTab {
                    activeSessionView(tab: activeTab)
                } else {
                    hostsListView
                }
            }
            .navigationTitle("Cliente SSH")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !sshService.tabs.isEmpty {
                        Button {
                            isShowingHostsDrawer = true
                        } label: {
                            Image(systemName: "list.bullet.rectangle")
                        }
                        .accessibilityLabel("Hosts Salvos")
                    }

                    Button {
                        sshVM.isPresentingKeyManager = true
                    } label: {
                        Image(systemName: "key")
                    }
                    .accessibilityLabel("Gerenciador de Chaves")

                    Button {
                        sshVM.editingHost = nil
                        sshVM.isPresentingHostEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Novo Host SSH")
                }
            }
            .sheet(isPresented: $sshVM.isPresentingHostEditor) {
                SSHHostEditorView(host: sshVM.editingHost)
            }
            .sheet(isPresented: $sshVM.isPresentingKeyManager) {
                SSHKeyManagerView()
            }
            .sheet(isPresented: $isShowingHostsDrawer) {
                NavigationStack {
                    hostsListView
                        .navigationTitle("Conectar Host SSH")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Fechar") { isShowingHostsDrawer = false }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Barra de Abas Múltiplas

    private var tabsStripBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sshService.tabs) { tab in
                    let isSelected = tab.id == selectedTab?.id
                    HStack(spacing: 6) {
                        Circle()
                            .fill(tabColor(tab.state))
                            .frame(width: 7, height: 7)

                        Button {
                            sshService.selectedTabId = tab.id
                        } label: {
                            Text(tab.title)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)

                        Button {
                            sshService.closeTab(id: tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isSelected ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(.secondarySystemBackground))
    }

    private func activeSessionView(tab: SSHSessionTab) -> some View {
        SSHSessionContainerView(tab: tab)
    }

    private var hostsListView: some View {
        List {
            let activeVMs = vmManagerVM.vms.filter { qemuService.status(for: $0.id) == .running && $0.sshHostPort != nil }
            if !activeVMs.isEmpty {
                Section("VMs Ubuntu em Execução (Localhost)") {
                    ForEach(activeVMs) { vm in
                        Button {
                            isShowingHostsDrawer = false
                            sshVM.quickConnectToVM(vm)
                        } label: {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vm.name)
                                        .font(.headline)
                                    Text("ubuntu@127.0.0.1:\(vm.sshHostPort ?? 2222)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("Conectar")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }

            Section("Hosts Salvos") {
                if sshService.savedHosts.isEmpty {
                    Text("Nenhum host SSH salvo. Toque em + para adicionar.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sshService.savedHosts) { profile in
                        HStack {
                            Button {
                                isShowingHostsDrawer = false
                                sshVM.connect(to: profile)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("\(profile.username)@\(profile.host):\(profile.port) • \(profile.authType.displayName)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button {
                                sshVM.editingHost = profile
                                sshVM.isPresentingHostEditor = true
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            sshVM.deleteHost(id: sshService.savedHosts[index].id)
                        }
                    }
                }
            }
        }
    }

    private func tabColor(_ state: SSHConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }
}

/// Subview observando diretamente o `SSHSessionTab` selecionado para atualizar status e terminal em tempo real.
private struct SSHSessionContainerView: View {
    @ObservedObject var tab: SSHSessionTab
    @EnvironmentObject private var sshService: SSHService
    @EnvironmentObject private var sshVM: SSHViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tab.state.label)
                    .font(.caption)
                    .foregroundStyle(tab.state.isConnected ? .green : .secondary)
                    .lineLimit(1)

                Spacer()

                if !tab.state.isConnected {
                    Button("Reconectar") {
                        sshService.reconnectTab(tab)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemBackground))

            SwiftTermTerminalView(
                sessionIdentifier: tab.id,
                fontSize: sshVM.fontSize,
                onAttach: { view in
                    tab.attach(terminalView: view)
                },
                onSendBytes: { bytes in
                    sshVM.handleTabSend(bytes: bytes, tab: tab)
                },
                onSizeChanged: { cols, rows in
                    tab.resize(cols: cols, rows: rows)
                }
            )
            .id(tab.id)

            TerminalAccessoryBar(
                ctrlActive: $sshVM.ctrlActive,
                altActive: $sshVM.altActive,
                onSendBytes: { bytes in
                    tab.sendBytes(bytes)
                },
                onPaste: {
                    sshVM.pasteClipboard(to: tab)
                }
            )
        }
    }
}

