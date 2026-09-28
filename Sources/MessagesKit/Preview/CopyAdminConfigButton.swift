import SwiftUI

/// Un botón para copiar la configuración de la app (tema, rutas, acciones, pantallas, eventos y
/// atributos) y pegarla en el admin: Apps → Importar desde la app. Ponlo donde quieras, por
/// ejemplo en unos ajustes de depuración.
public struct CopyAdminConfigButton: View {
    @State private var copied = false

    public init() {}

    public var body: some View {
        Button {
            Task {
                guard let json = await Messages.appReport() else { return }
                SystemBridge.copy(json)
                withAnimation(.smooth) { copied = true }
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.smooth) { copied = false }
            }
        } label: {
            Label(copied ? L.string("Copiado", "Copied") : L.string("Copiar config del admin", "Copy admin config"),
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .contentShape(.rect)
        }
    }
}
