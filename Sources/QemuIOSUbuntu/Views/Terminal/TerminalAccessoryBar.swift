import SwiftUI

/// Barra acessória de teclas especiais para uso confortável no iPhone/iPad:
/// Esc, Tab, Ctrl (toggle + Ctrl+C), Alt, setas direcionais, símbolos comuns e Colar.
public struct TerminalAccessoryBar: View {
    @Binding public var ctrlActive: Bool
    @Binding public var altActive: Bool
    public let onSendBytes: ([UInt8]) -> Void
    public let onPaste: () -> Void
    public let onCopyAllHint: (() -> Void)?

    public init(
        ctrlActive: Binding<Bool>,
        altActive: Binding<Bool>,
        onSendBytes: @escaping ([UInt8]) -> Void,
        onPaste: @escaping () -> Void,
        onCopyAllHint: (() -> Void)? = nil
    ) {
        self._ctrlActive = ctrlActive
        self._altActive = altActive
        self.onSendBytes = onSendBytes
        self.onPaste = onPaste
        self.onCopyAllHint = onCopyAllHint
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                keyButton("Esc") { onSendBytes([0x1B]) }
                keyButton("Tab") { onSendBytes([0x09]) }

                toggleKeyButton("Ctrl", isActive: $ctrlActive)
                toggleKeyButton("Alt", isActive: $altActive)

                keyButton("Ctrl+C", tint: .red) { onSendBytes([0x03]) }
                keyButton("Ctrl+D") { onSendBytes([0x04]) }
                keyButton("Ctrl+L") { onSendBytes([0x0C]) }

                Divider().frame(height: 20)

                iconButton("arrow.up", label: "Seta cima") { onSendBytes([0x1B, 0x5B, 0x41]) }
                iconButton("arrow.down", label: "Seta baixo") { onSendBytes([0x1B, 0x5B, 0x42]) }
                iconButton("arrow.left", label: "Seta esquerda") { onSendBytes([0x1B, 0x5B, 0x44]) }
                iconButton("arrow.right", label: "Seta direita") { onSendBytes([0x1B, 0x5B, 0x43]) }

                Divider().frame(height: 20)

                keyButton("/") { onSendBytes(Array("/".utf8)) }
                keyButton("-") { onSendBytes(Array("-".utf8)) }
                keyButton("|") { onSendBytes(Array("|".utf8)) }
                keyButton("~") { onSendBytes(Array("~".utf8)) }

                Divider().frame(height: 20)

                Button(action: onPaste) {
                    Label("Colar", systemImage: "doc.on.clipboard")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(.secondarySystemBackground))
    }

    private func keyButton(_ title: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .frame(width: 30, height: 28)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func toggleKeyButton(_ title: String, isActive: Binding<Bool>) -> some View {
        Button {
            isActive.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(isActive.wrappedValue ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isActive.wrappedValue ? Color.accentColor : Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

