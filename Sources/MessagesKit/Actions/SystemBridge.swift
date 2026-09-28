import SwiftUI
#if os(iOS)
import UIKit
import SafariServices
#else
import AppKit
#endif

/// Lo poco que el sistema solo ofrece fuera de SwiftUI: Safari dentro de la app, la hoja
/// de compartir desde código, el portapapeles y el registro de avisos.
@MainActor
enum SystemBridge {
    #if os(iOS)
    static var topViewController: UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
    #endif

    /// Abre la web en un Safari dentro de la app. `false` si no se puede (macOS).
    static func presentSafari(_ url: URL) -> Bool {
        #if os(iOS)
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let top = topViewController else { return false }
        top.present(SFSafariViewController(url: url), animated: true)
        return true
        #else
        return false
        #endif
    }

    static func share(items: [String]) {
        #if os(iOS)
        let objects: [Any] = items.map { item -> Any in
            if let url = URL(string: item), url.scheme != nil { return url }
            return item
        }
        let sheet = UIActivityViewController(activityItems: objects, applicationActivities: nil)
        if let pop = sheet.popoverPresentationController, let view = topViewController?.view {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        topViewController?.present(sheet, animated: true)
        #else
        guard let view = NSApp.keyWindow?.contentView else { copy(items.joined(separator: " ")); return }
        NSSharingServicePicker(items: items).show(relativeTo: .zero, of: view, preferredEdge: .minY)
        #endif
    }

    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    static func registerForRemoteNotifications() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// Desarrollo (APNs sandbox) si la app lleva un perfil con `aps-environment` de desarrollo.
    /// Las de TestFlight y App Store usan producción.
    nonisolated static var isSandboxBuild: Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "<key>aps-environment</key>") else { return false }
        return text[range.upperBound...].prefix(80).contains("development")
    }
}
