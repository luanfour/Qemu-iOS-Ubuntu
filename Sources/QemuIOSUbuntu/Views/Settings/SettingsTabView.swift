import SwiftUI

/// Aba "Configurações": aparência, Modo Servidor em segundo plano, diagnóstico JIT/TCI,
/// status do backend `libqemu` e acesso ao gerenciador de armazenamento.
public struct SettingsTabView: View {
    @EnvironmentObject private var settingsVM: SettingsStorageViewModel
    @EnvironmentObject private var backgroundService: BackgroundServerService
    @EnvironmentObject private var qemuService: QEMUService

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("Aparência") {
                    Picker("Tema", selection: $settingsVM.themePreference) {
                        ForEach(AppThemePreference.allCases) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("Manter servidor ativo em 2º plano", isOn: $backgroundService.isServerModeEnabled)
                    Toggle("Notificações locais de status", isOn: $backgroundService.notificationsEnabled)

                    HStack {
                        Text("Áudio silencioso Keep-Alive")
                        Spacer()
                        Text(backgroundService.isKeepAliveAudioActive ? "Ativo" : "Inativo")
                            .foregroundStyle(backgroundService.isKeepAliveAudioActive ? .green : .secondary)
                    }

                    if let warning = backgroundService.lastBackgroundWarning {
                        Text("Aviso de áudio: \(warning)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Modo Servidor (Background)")
                } footer: {
                    Text("Usa AVAudioSession silencioso + BGProcessingTask para reduzir a suspensão pelo iOS enquanto VMs Ubuntu Server estiverem rodando.")
                }

                Section {
                    HStack {
                        Text("Backend Ativo")
                        Spacer()
                        Text(qemuService.activeBackendName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Status JIT (CS_DEBUGGED)")
                        Spacer()
                        Text(qemuService.capabilities.isJITEnabled ? "Habilitado (StikDebug/Debugger)" : "Desativado (Modo TCI)")
                            .foregroundStyle(qemuService.capabilities.isJITEnabled ? .green : .orange)
                    }

                    HStack {
                        Text("StikDebug / StikJIT no iPhone")
                        Spacer()
                        Text(qemuService.capabilities.hasOnDeviceJITEnabler ? "Detectado" : "Não detectado")
                            .foregroundStyle(qemuService.capabilities.hasOnDeviceJITEnabler ? .green : .secondary)
                    }

                    HStack {
                        Text("Bundle ID em Execução")
                        Spacer()
                        Text(qemuService.capabilities.runtimeBundleID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Toggle("Solicitar JIT (StikDebug) ao abrir o app", isOn: $qemuService.autoRequestStikDebugOnLaunch)

                    if !qemuService.capabilities.isJITEnabled {
                        Button {
                            qemuService.requestJITWithStikDebug()
                        } label: {
                            Label("Habilitar JIT agora via StikDebug", systemImage: "bolt.fill")
                        }
                    }

                    HStack {
                        Text("libqemu ARM64 / x86_64")
                        Spacer()
                        Text(qemuService.capabilities.isAnyEmbeddedQEMULinked ? "Linkado" : "Não linkado (Diagnóstico)")
                            .foregroundStyle(qemuService.capabilities.isAnyEmbeddedQEMULinked ? .green : .secondary)
                    }

                    Button("Reverificar Capacidades JIT") {
                        qemuService.refreshCapabilities()
                    }
                } header: {
                    Text("Motor QEMU & JIT / StikDebug")
                } footer: {
                    Text("Com StikDebug (LocalDevVPN + Pairing File), toque em 'Habilitar JIT agora via StikDebug' para ativar TCG multi-thread com tb-size ampliado no iPhone 16 Pro. Sem JIT, o QEMU usa TCI (estilo UTM SE).")
                }

                Section("Armazenamento") {
                    NavigationLink {
                        StorageManagerView()
                    } label: {
                        HStack {
                            Label("Gerenciar Discos, ISOs e Snapshots", systemImage: "internaldrive")
                            Spacer()
                            Text(settingsVM.formatBytes(settingsVM.breakdown.totalAppBytes))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Rede Local do Servidor") {
                    HStack {
                        Text("IP Wi-Fi (en0)")
                        Spacer()
                        Text(qemuService.telemetry.localIPAddress)
                            .font(.subheadline.monospaced())
                    }
                    HStack {
                        Text("Portas Expostas")
                        Spacer()
                        Text("\(qemuService.telemetry.exposedPorts.count)")
                            .monospacedDigit()
                    }
                }

                Section("Sobre") {
                    HStack {
                        Text("Projeto")
                        Spacer()
                        Text("Qemu-ios-ubuntu (xtool + SwiftPM)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Alvo mínimo")
                        Spacer()
                        Text("iOS 16.0+")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Configurações")
            .onAppear {
                settingsVM.refreshStorage()
                qemuService.refreshCapabilities()
            }
        }
    }
}

