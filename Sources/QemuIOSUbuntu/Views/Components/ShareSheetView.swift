import SwiftUI
import UIKit

/// Wrapper SwiftUI sobre `UIActivityViewController` para exportar pacotes `.qemuvm` ou chaves públicas SSH.
public struct ShareSheetView: UIViewControllerRepresentable {
    public let items: [Any]

    public init(items: [Any]) {
        self.items = items
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

