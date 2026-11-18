import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Seletor de arquivos nativo do iOS (`UIDocumentPickerViewController`) para importar
/// ISOs do Ubuntu Server, discos QCOW2 ou pacotes `.qemuvm`.
public struct DocumentPickerView: UIViewControllerRepresentable {
    public let contentTypes: [UTType]
    public let allowsMultipleSelection: Bool
    public let onPick: ([URL]) -> Void

    public init(
        contentTypes: [UTType],
        allowsMultipleSelection: Bool = false,
        onPick: @escaping ([URL]) -> Void
    ) {
        self.contentTypes = contentTypes
        self.allowsMultipleSelection = allowsMultipleSelection
        self.onPick = onPick
    }

    public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    public final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

public extension UTType {
    /// Tipo UTType para imagens `.iso` (fallback seguro além de `public.iso-image` / `.data`).
    static var isoDiskImage: UTType {
        UTType(filenameExtension: "iso") ?? .data
    }

    /// Tipo UTType para pacotes `.qemuvm` (diretórios exportados).
    static var qemuVMFolder: UTType {
        .folder
    }
}

