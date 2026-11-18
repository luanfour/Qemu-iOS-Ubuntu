import AVFoundation
import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// Serviço responsável pelo "Modo Servidor" no iOS:
/// mantém o processo ativo em segundo plano o máximo possível usando áudio silencioso contínuo,
/// `beginBackgroundTask`, agendamento `BGProcessingTask` e notificações locais de status.
@MainActor
public final class BackgroundServerService: ObservableObject {
    public static let bgTaskIdentifier = "com.luanquaresma.qemu-ios-ubuntu.vmkeepalive"

    @Published public var isServerModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isServerModeEnabled, forKey: "serverModeEnabled")
            if !isServerModeEnabled {
                stopKeepAlive()
            }
        }
    }
    @Published public var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "serverNotificationsEnabled")
        }
    }
    @Published public private(set) var isKeepAliveAudioActive: Bool = false
    @Published public private(set) var lastBackgroundWarning: String?

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var activeVMNames: [UUID: String] = [:]

    public init() {
        self.isServerModeEnabled = UserDefaults.standard.object(forKey: "serverModeEnabled") as? Bool ?? true
        self.notificationsEnabled = UserDefaults.standard.object(forKey: "serverNotificationsEnabled") as? Bool ?? true
    }

    public func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            processingTask.expirationHandler = {
                processingTask.setTaskCompleted(success: false)
            }
            Task { @MainActor in
                self.sendStatusNotification(
                    title: "Servidor QEMU ativo",
                    body: "Monitoramento em segundo plano verificado pelo iOS."
                )
                processingTask.setTaskCompleted(success: true)
            }
        }
    }

    public func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func onVMStarted(vm: VirtualMachine) {
        activeVMNames[vm.id] = vm.name
        if isServerModeEnabled {
            startKeepAliveIfNeeded()
        }
        if notificationsEnabled {
            let sshInfo = vm.sshHostPort.map { " | SSH porta \($0)" } ?? ""
            sendStatusNotification(
                title: "VM iniciada: \(vm.name)",
                body: "Modo servidor ativo (\(vm.ramMB) MB RAM\(sshInfo))."
            )
        }
    }

    public func onVMStopped(vmId: UUID, vmName: String, hasRemainingActiveVMs: Bool) {
        activeVMNames.removeValue(forKey: vmId)
        if !hasRemainingActiveVMs {
            stopKeepAlive()
        }
        if notificationsEnabled {
            sendStatusNotification(
                title: "VM encerrada: \(vmName)",
                body: "A máquina virtual foi desligada."
            )
        }
    }

    public func handleAppDidEnterBackground() {
        guard isServerModeEnabled, !activeVMNames.isEmpty else { return }
        startKeepAliveIfNeeded()
        beginExpiringBackgroundTask()
        scheduleBGProcessingTask()

        if notificationsEnabled {
            let names = activeVMNames.values.sorted().joined(separator: ", ")
            sendStatusNotification(
                title: "Servidor Ubuntu rodando em 2º plano",
                body: "Ativa(s): \(names). Áudio silencioso mantendo o processo vivo."
            )
        }
    }

    public func handleAppWillEnterForeground() {
        endExpiringBackgroundTask()
    }

    // MARK: - Áudio silencioso Keep-Alive

    public func startKeepAliveIfNeeded() {
        guard !isKeepAliveAudioActive else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)

            let sampleRate: Double = 44100
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let silentBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate)) else {
                throw AppError.backgroundAudioFailed("Não foi possível alocar buffer PCM silencioso.")
            }
            silentBuffer.frameLength = silentBuffer.frameCapacity
            if let floatData = silentBuffer.floatChannelData?[0] {
                memset(floatData, 0, Int(silentBuffer.frameLength) * MemoryLayout<Float>.size)
            }

            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.0
            try engine.start()

            player.scheduleBuffer(silentBuffer, at: nil, options: [.loops], completionHandler: nil)
            player.play()

            self.audioEngine = engine
            self.playerNode = player
            self.isKeepAliveAudioActive = true
            self.lastBackgroundWarning = nil
        } catch {
            self.lastBackgroundWarning = error.localizedDescription
            self.isKeepAliveAudioActive = false
        }
    }

    public func stopKeepAlive() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        isKeepAliveAudioActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        endExpiringBackgroundTask()
    }

    private func beginExpiringBackgroundTask() {
        endExpiringBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "QEMUVMServerKeepAlive") { [weak self] in
            Task { @MainActor in
                self?.endExpiringBackgroundTask()
            }
        }
    }

    private func endExpiringBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private func scheduleBGProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: Self.bgTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func sendStatusNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "qemu-status-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

