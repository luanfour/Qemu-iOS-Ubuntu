import SwiftUI

/// Aba "Terminal": conecta o emulador `SwiftTerm` diretamente à console serial (`-serial` / `-nographic`) da VM ativa.
public struct TerminalTabView: View {
    @EnvironmentObject private var vmManagerVM: VMManagerViewModel
    @EnvironmentObject private var qemuService: QEMUService
    @EnvironmentObject private var terminalService: TerminalService
    @EnvironmentObject private var terminalVM: TerminalViewModel

    @State private var quickCommand: String = ""

    public init() {}

    private var activeVM: VirtualMachine? {
        if let id = terminalVM.selectedVMId,
           let match = vmManagerVM.vms.first(where: { $0.id == id }) {
            return match
        }
        if let firstRunningId = qemuService.runningVMIds.first,
           let runningVM = vmManagerVM.vms.first(where: { $0.id == firstRunningId }) {
            return runningVM
        }
        return vmManagerVM.vms.first
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                vmSelectorHeader

                if let vm = activeVM {
                    let status = qemuService.status(for: vm.id)

                    if status == .stopped {
                        stoppedPlaceholder(for: vm)
                    } else {
                        SwiftTermTerminalView(
                            sessionIdentifier: vm.id,
                            fontSize: terminalVM.fontSize,
                            onAttach: { view in
                                terminalService.attach(terminalView: view, to: vm.id)
                            },
                            onSendBytes: { bytes in
                                terminalVM.handleTerminalSend(bytes: bytes, for: vm.id)
                            },
                            onSizeChanged: { _, _ in }
                        )
                        .id(vm.id)

                        TerminalAccessoryBar(
                            ctrlActive: $terminalVM.ctrlActive,
                            altActive: $terminalVM.altActive,
                            onSendBytes: { bytes in
                                terminalVM.sendSpecialSequence(bytes, to: vm.id)
                            },
                            onPaste: {
                                terminalVM.pasteFromClipboard(to: vm.id)
                            }
                        )
                    }
                } else {
                    Text("Nenhuma máquina virtual configurada.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Terminal Serial")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let vm = activeVM {
                        Menu {
                            Button {
                                terminalVM.fontSize = min(22, terminalVM.fontSize + 1)
                            } label: {
                                Label("Aumentar Fonte", systemImage: "textformat.size.larger")
                            }
                            Button {
                                terminalVM.fontSize = max(9, terminalVM.fontSize - 1)
                            } label: {
                                Label("Diminuir Fonte", systemImage: "textformat.size.smaller")
                            }
                            Divider()
                            Button {
                                terminalVM.clearTerminal(for: vm.id)
                            } label: {
                                Label("Limpar Tela", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
    }

    private var vmSelectorHeader: some View {
        HStack(spacing: 10) {
            Picker("VM", selection: Binding(
                get: { activeVM?.id ?? UUID() },
                set: { terminalVM.selectedVMId = $0 }
            )) {
                ForEach(vmManagerVM.vms) { vm in
                    Text(vm.name).tag(vm.id)
                }
            }
            .pickerStyle(.menu)

            Spacer()

            if let vm = activeVM {
                StatusBadgeView(status: qemuService.status(for: vm.id))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private func stoppedPlaceholder(for vm: VirtualMachine) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)

            Text("Console serial de '\(vm.name)' está parada")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("Inicie a máquina virtual para conectar o emulador SwiftTerm à saída `-serial` do Ubuntu Server.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button {
                vmManagerVM.toggleStartPause(vm)
            } label: {
                Label("Iniciar VM Agora", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

