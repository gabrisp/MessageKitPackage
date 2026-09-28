import SwiftUI
import WebKit

// Todo lo que solo existe en iOS 26 / macOS 26, con su alternativa para iOS 17–25 / macOS 14–15.
// En 26 se ve exactamente igual que siempre (Liquid Glass nativo); antes, con materiales y
// botones del sistema. Las vistas usan estos modificadores y no llevan `#available` sueltos.

extension View {
    /// La superficie de un mensaje (tarjeta, banner, toast): cristal del tema en 26, material antes.
    @ViewBuilder
    func messageSurface<S: Shape>(_ theme: MessagesTheme, interactive: Bool = false, in shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(theme.surfaceGlass(interactive: interactive), in: shape)
        } else {
            background {
                ZStack {
                    if theme.glass == .clear { shape.fill(.ultraThinMaterial) } else { shape.fill(.regularMaterial) }
                    if let tint = theme.glassTint { shape.fill(tint) }
                    shape.stroke(.white.opacity(0.18), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            }
        }
    }

    /// Cristal sin tema (avisos del modo prueba).
    @ViewBuilder
    func messagePlainSurface<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// Estilo de botón: `.glassProminent`/`.glass` en 26, `.borderedProminent`/`.bordered` antes.
    @ViewBuilder
    func messageButtonStyle(prominent: Bool) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// Borde suave del scroll bajo las barras (solo 26; antes no hace falta).
    @ViewBuilder
    func messageSoftScrollEdge(_ edges: Edge.Set) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }

    /// La imagen de cabecera se extiende bajo la zona segura (solo 26).
    @ViewBuilder
    func messageBackgroundExtension() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            backgroundExtensionEffect()
        } else {
            self
        }
    }
}

/// Agrupa cristales para que se fundan y no se pinte cristal encima de cristal (solo 26).
struct MessageGlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Web

/// Página web: el `WebView` de SwiftUI en 26, `WKWebView` antes.
struct MessageWebView: View {
    let url: URL

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            WebView(url: url)
        } else {
            LegacyWebView(url: url)
        }
    }
}

#if os(iOS)
private struct LegacyWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        if view.url != url { view.load(URLRequest(url: url)) }
    }
}
#else
private struct LegacyWebView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url { view.load(URLRequest(url: url)) }
    }
}
#endif
