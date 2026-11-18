import SwiftUI
import UniformTypeIdentifiers

/// Formulário modal para criação e edição completa de uma Máquina Virtual QEMU.
public struct VMEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vmManagerVM: VMManagerViewModel

    @State private var draft: VirtualMachine
    @State private var isCreating: Bool
    @State private var isShowingISOPicker = false

    @State private var newRuleName = ""
    @State private var newRuleHostPort = "2222"
    @State private var newRuleGuestPort = "22"
    @State private var newRuleProtocol: PortForwardRule.TransportProtocol = .tcp

    public init(vm: VirtualMachine? = nil) {
        if let vm {
            _draft = State(initialValue: vm)
            _isCreating = State(initialValue: false)
        } else {
            _draft = State(initialValue: VirtualMachine())
            _isCreating = State(initialValue: true)
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Identificação e Arquitetura") {
                    TextField("Nome da VM", text: $draft.name)

                    Picker("Arquitetura", selection: $draft.architecture) {
                        ForEach(VMArchitecture.allCases) { arch in
                            Text(arch.displayName).tag(arch)
                        }
                    }

                    Picker("Aceleração TCG", selection: $draft.accelerationMode) {
                        ForEach(VMAccelerationMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                Section("Hardware Virtual") {
                    Stepper("Núcleos de CPU: \(draft.cpuCores)", value: $draft.cpuCores, in: 1...8)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Memória RAM")
                            Spacer()
                            Text("\(draft.ramMB) MB")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(draft.ramMB) },
                                set: { draft.ramMB = Int($0 / 128) * 128 }
                            ),
                            in: 256...4096,
                            step: 128
                        )
                    }

                    Stepper("Disco QCOW2: \(draft.diskSizeGB) GB", value: $draft.diskSizeGB, in: 4...256, step: 4)
                        .disabled(!isCreating)
                    if !isCreating {
                        Text("O tamanho virtual do disco QCOW2 existente não pode ser reduzido aqui.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Imagem ISO (Ubuntu Server) e Boot") {
                    Picker("ISO Anexada", selection: $draft.attachedISOId) {
                        Text("Nenhuma").tag(UUID?.none)
                        ForEach(vmManagerVM.isos) { iso in
                            Text("\(iso.displayName) (\(iso.formattedSize))").tag(UUID?.some(iso.id))
                        }
                    }

                    Button {
                        isShowingISOPicker = true
                    } label: {
                        Label("Importar nova ISO do dispositivo...", systemImage: "square.and.arrow.down")
                    }

                    Picker("Ordem de Boot", selection: $draft.bootOrder) {
                        ForEach(VMBootOrder.allCases) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                }

                Section("Rede NAT e Redirecionamento de Portas") {
                    Toggle("Habilitar rede NAT (QEMU User Mode)", isOn: $draft.natEnabled)

                    if draft.natEnabled {
                        ForEach(draft.portForwards) { rule in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(rule.name)
                                        .font(.subheadline.weight(.medium))
                                    Text("\(rule.transport.rawValue.uppercased()) Host :\(rule.hostPort) → Guest :\(rule.guestPort)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .onDelete { offsets in
                            draft.portForwards.remove(atOffsets: offsets)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Adicionar regra hostfwd")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            HStack {
                                TextField("Serviço (ex: HTTPS)", text: $newRuleName)
                                Picker("", selection: $newRuleProtocol) {
                                    ForEach(PortForwardRule.TransportProtocol.allCases) { proto in
                                        Text(proto.rawValue.uppercased()).tag(proto)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 85)
                            }

                            HStack {
                                TextField("Porta Host", text: $newRuleHostPort)
                                    .keyboardType(.numberPad)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                TextField("Porta Guest", text: $newRuleGuestPort)
                                    .keyboardType(.numberPad)

                                Button("Adicionar") {
                                    addPortForwardRule()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Console Serial e Vídeo Opcional") {
                    Toggle("Console Serial (-serial / Terminal)", isOn: $draft.serialConsoleEnabled)
                    Toggle("Servidor VNC Integrado", isOn: $draft.enableVNC)
                    if draft.enableVNC {
                        HStack {
                            Text("Porta VNC")
                            Spacer()
                            TextField("5900", value: $draft.vncPort, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                        }
                    }

                    Toggle("Servidor SPICE (Cliente externo)", isOn: $draft.enableSPICE)
                    if draft.enableSPICE {
                        HStack {
                            Text("Porta SPICE")
                            Spacer()
                            TextField("5930", value: $draft.spicePort, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                        }
                    }

                    TextField("Argumentos extras QEMU (opcional)", text: $draft.extraKernelArgs)
                        .font(.caption.monospaced())
                }
            }
            .navigationTitle(isCreating ? "Nova VM Ubuntu" : "Editar VM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        let cleanName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        draft.name = cleanName.isEmpty ? "Ubuntu Server" : cleanName
                        vmManagerVM.saveVM(draft)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isShowingISOPicker) {
                DocumentPickerView(contentTypes: [.isoDiskImage, .data]) { urls in
                    if let first = urls.first {
                        vmManagerVM.importISO(from: first)
                    }
                }
            }
        }
    }

    private func addPortForwardRule() {
        guard let host = UInt16(newRuleHostPort), let guest = UInt16(newRuleGuestPort) else { return }
        let label = newRuleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Porta \(guest)"
            : newRuleName
        draft.portForwards.append(
            PortForwardRule(name: label, transport: newRuleProtocol, hostPort: host, guestPort: guest)
        )
        newRuleName = ""
    }
}

