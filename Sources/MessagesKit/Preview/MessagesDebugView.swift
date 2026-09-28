import SwiftUI

/// Menú de depuración para la app anfitriona: las campañas que le ha servido el hub (forzar
/// una), pegar un JSON para verlo y borrar el estado local.
public struct MessagesDebugView: View {
    @State private var json = ""
    @State private var error: String?
    @State private var campaigns: [Campaign] = []
    @State private var sync: SyncStatus?

    public init() {}

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                section(L.string("Hub", "Hub")) {
                    SyncStatusView(status: sync)
                        .padding(16)
                }
                section(L.string("Para el admin", "For the admin")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L.string("Copia el tema, las rutas, acciones, pantallas, eventos y atributos que usa esta app, y pégalo en el admin: Apps → Importar desde la app.",
                                      "Copies this app's theme, routes, actions, screens, events and attributes. Paste it in the admin: Apps → Import from app."))
                            .font(.footnote).foregroundStyle(.secondary)
                        CopyAdminConfigButton()
                            .frame(maxWidth: .infinity)
                        .messageButtonStyle(prominent: true)
                    }
                    .padding(16)
                }
                section(L.string("Servidas por el hub", "Served by the hub")) {
                    if campaigns.isEmpty {
                        ContentUnavailableView(L.string("Sin campañas", "No campaigns"), systemImage: "tray",
                                               description: Text(L.string("Ninguna le toca a este usuario ahora.", "None apply to this user right now.")))
                    } else {
                        ForEach(campaigns) { c in
                            DebugRow(title: c.name, subtitle: "\(c.presentation.style.rawValue) · \(c.trigger.on.rawValue) · \(c.id)", isLast: c.id == campaigns.last?.id) {
                                Messages.show(campaignId: c.id)
                            }
                        }
                    }
                }
                section(L.string("Ejemplos (modo prueba)", "Examples (test mode)")) {
                    ForEach(Messages.examples) { c in
                        DebugRow(title: c.name, subtitle: c.presentation.style.rawValue, isLast: c.id == Messages.examples.last?.id) {
                            Messages.preview(campaign: c, language: L.current.hasPrefix("es") ? "es" : "en")
                        }
                    }
                }
                section(L.string("Pegar JSON", "Paste JSON")) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("{ \"presentation\": … }", text: $json, axis: .vertical)
                            .font(.footnote.monospaced())
                            .lineLimit(4...12)
                            .textFieldStyle(.roundedBorder)
                        if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                        Button(L.string("Pintar", "Render")) {
                            do { try Messages.preview(json: json); error = nil } catch { self.error = String(describing: error) }
                        }
                        .messageButtonStyle(prominent: true)
                        .disabled(json.isEmpty)
                    }
                    .padding(16)
                }
                Button(L.string("Borrar estado local", "Reset local state"), role: .destructive) {
                    Messages.resetLocalState()
                    campaigns = []
                }
                .messageButtonStyle(prominent: false)
            }
            .padding(20)
        }
        .task {
            campaigns = Messages.cachedCampaigns
            sync = Messages.lastSync
        }
        .refreshable {
            sync = await Messages.refresh()
            campaigns = Messages.cachedCampaigns
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.leading, 16)
            VStack(spacing: 0, content: content)
                .background(.background.secondary, in: .rect(cornerRadius: 22, style: .continuous))
        }
    }
}

/// Fila propia (sin `List`): pulsado, separador dibujado por la fila.
struct DebugRow: View {
    let title: String
    let subtitle: String
    let isLast: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "play.fill").foregroundStyle(.tint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(.separator).frame(height: 1 / 3).padding(.leading, 16) }
        }
    }
}

struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear))
    }
}

/// La última petición al hub, en claro.
struct SyncStatusView: View {
    let status: SyncStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = status {
                Label(s.ok ? L.string("Última petición correcta", "Last request OK") : L.string("La última petición falló", "The last request failed"),
                      systemImage: s.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(s.ok ? .green : .orange)
                Group {
                    Text(s.date, style: .relative) + Text(L.string(" · \(s.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))", " · \(s.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))"))
                    Text("userId: \(s.userId)").textSelection(.enabled)
                    if let error = s.error {
                        Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    } else {
                        Text(L.string("\(s.campaigns) campañas para este usuario\(s.notModified ? " (sin cambios)" : "")",
                                      "\(s.campaigns) campaigns for this user\(s.notModified ? " (unchanged)" : "")"))
                        if s.campaigns == 0 {
                            Text(L.string("Si esperabas alguna: ¿está publicada, es para esta app, y si va a usuarios concretos, está este userId?",
                                          "If you expected one: is it published, for this app, and if it targets specific users, is this userId there?"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.footnote.monospaced())
            } else {
                Text(L.string("Todavía no se ha pedido nada al hub. Desliza hacia abajo para pedir ahora.", "Nothing requested from the hub yet. Pull down to request now."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
