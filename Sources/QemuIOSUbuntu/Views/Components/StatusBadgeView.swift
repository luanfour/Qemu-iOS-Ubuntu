import SwiftUI

/// Selo visual indicando o estado atual de execução de uma VM.
public struct StatusBadgeView: View {
    public let status: VMStatus

    public init(status: VMStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(status.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.14))
        .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch status {
        case .running: return .green
        case .paused: return .orange
        case .starting, .stopping: return .blue
        case .stopped: return .secondary
        case .error: return .red
        }
    }
}

