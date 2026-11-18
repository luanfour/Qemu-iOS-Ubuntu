import SwiftTerm
import SwiftUI
import UIKit

/// Wrapper SwiftUI sobre `SwiftTerm.TerminalView` (UIKit) para console serial e sessões SSH.
/// Garante suporte ao teclado completo do iOS, seleção, rolagem, copiar/colar e redimensionamento automático.
public struct SwiftTermTerminalView: UIViewRepresentable {
    public let sessionIdentifier: UUID
    public let fontSize: CGFloat
    public let onAttach: (TerminalView) -> Void
    public let onSendBytes: (ArraySlice<UInt8>) -> Void
    public let onSizeChanged: (Int, Int) -> Void

    public init(
        sessionIdentifier: UUID,
        fontSize: CGFloat,
        onAttach: @escaping (TerminalView) -> Void,
        onSendBytes: @escaping (ArraySlice<UInt8>) -> Void,
        onSizeChanged: @escaping (Int, Int) -> Void
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.fontSize = fontSize
        self.onAttach = onAttach
        self.onSendBytes = onSendBytes
        self.onSizeChanged = onSizeChanged
    }

    public func makeUIView(context: Context) -> TerminalView {
        let terminalView = TerminalView(frame: .zero)
        terminalView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.nativeBackgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1.0)
        terminalView.nativeForegroundColor = UIColor(red: 0.92, green: 0.94, blue: 0.96, alpha: 1.0)
        terminalView.caretColor = UIColor.systemGreen
        terminalView.terminalDelegate = context.coordinator

        context.coordinator.boundSessionId = sessionIdentifier
        onAttach(terminalView)
        return terminalView
    }

    public func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.parent = self
        if uiView.font.pointSize != fontSize {
            uiView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        if context.coordinator.boundSessionId != sessionIdentifier {
            context.coordinator.boundSessionId = sessionIdentifier
            let clearSeq: [UInt8] = Array("\u{001B}[2J\u{001B}[H".utf8)
            uiView.feed(byteArray: ArraySlice(clearSeq))
            onAttach(uiView)
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public final class Coordinator: NSObject, TerminalViewDelegate {
        var parent: SwiftTermTerminalView
        var boundSessionId: UUID?

        init(_ parent: SwiftTermTerminalView) {
            self.parent = parent
        }

        public func send(source: TerminalView, data: ArraySlice<UInt8>) {
            parent.onSendBytes(data)
        }

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            parent.onSizeChanged(newCols, newRows)
        }

        public func setTerminalTitle(source: TerminalView, title: String) {}

        public func scrolled(source: TerminalView, position: Double) {}

        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        public func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }

        public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

