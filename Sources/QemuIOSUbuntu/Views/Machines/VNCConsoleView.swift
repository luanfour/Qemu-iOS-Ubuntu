import SwiftUI

/// Console gráfico VNC opcional conectado ao framebuffer RFB do QEMU (`-vnc 127.0.0.1:5900`),
/// com opção de abrir cliente SPICE externo caso habilitado.
public struct VNCConsoleView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var vncService: VNCClientService

    public let vm: VirtualMachine
    @State private var quickTextInput: String = ""

    public init(vm: VirtualMachine) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    Label(vncService.statusMessage, systemImage: vncService.isConnected ? "display" : "display.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(vncService.isConnected ? .green : .secondary)

                    Spacer()

                    if vncService.isConnected {
                        Button("Reconectar") {
                            vncService.connect(host: "127.0.0.1", port: vm.vncPort)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    } else {
                        Button("Conectar VNC :\(vm.vncPort)") {
                            vncService.connect(host: "127.0.0.1", port: vm.vncPort)
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal)

                GeometryReader { geo in
                    ZStack {
                        Color.black

                        if let image = vncService.framebufferImage {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onEnded { value in
                                            let fbSize = vncService.framebufferSize
                                            let x = Int((value.location.x / max(1, geo.size.width)) * fbSize.width)
                                            let y = Int((value.location.y / max(1, geo.size.height)) * fbSize.height)
                                            vncService.sendPointerEvent(x: x, y: y, buttonMask: 1)
                                            vncService.sendPointerEvent(x: x, y: y, buttonMask: 0)
                                        }
                                )
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "desktopcomputer")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.gray)
                                Text("Console Gráfico VNC / SPICE")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text("Conecte-se à porta VNC \(vm.vncPort) quando a VM estiver rodando com -vnc 127.0.0.1:\(max(0, Int(vm.vncPort) - 5900)).")
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                // Barra de teclas rápidas VNC + entrada de texto
                HStack(spacing: 8) {
                    TextField("Enviar texto para o VNC...", text: $quickTextInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Enviar") {
                        sendStringAsKeysyms(quickTextInput)
                        quickTextInput = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vncService.isConnected || quickTextInput.isEmpty)

                    Button("Enter") {
                        vncService.sendKeyEvent(keysym: 0xFF0D, down: true)
                        vncService.sendKeyEvent(keysym: 0xFF0D, down: false)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vncService.isConnected)
                }
                .padding(.horizontal)

                HStack(spacing: 10) {
                    Button("Esc") {
                        vncService.sendKeyEvent(keysym: 0xFF1B, down: true)
                        vncService.sendKeyEvent(keysym: 0xFF1B, down: false)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vncService.isConnected)

                    Button("Ctrl+Alt+Del") {
                        vncService.sendKeyEvent(keysym: 0xFFE3, down: true)
                        vncService.sendKeyEvent(keysym: 0xFFE9, down: true)
                        vncService.sendKeyEvent(keysym: 0xFFFF, down: true)
                        vncService.sendKeyEvent(keysym: 0xFFFF, down: false)
                        vncService.sendKeyEvent(keysym: 0xFFE9, down: false)
                        vncService.sendKeyEvent(keysym: 0xFFE3, down: false)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vncService.isConnected)

                    Spacer()

                    if vm.enableSPICE, let spiceURL = URL(string: "spice://127.0.0.1:\(vm.spicePort)") {
                        Button("Abrir SPICE") {
                            openURL(spiceURL)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Vídeo: \(vm.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") {
                        vncService.disconnect()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if vm.enableVNC {
                    vncService.connect(host: "127.0.0.1", port: vm.vncPort)
                }
            }
            .onDisappear {
                vncService.disconnect()
            }
        }
    }

    private func sendStringAsKeysyms(_ text: String) {
        for scalar in text.unicodeScalars {
            let ks = scalar.value
            vncService.sendKeyEvent(keysym: ks, down: true)
            vncService.sendKeyEvent(keysym: ks, down: false)
        }
    }
}

