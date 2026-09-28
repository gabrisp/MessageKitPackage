# MessagesKit

Mensajes a los usuarios de tus apps (ya publicadas en el App Store) que se crean y cambian desde el servidor, sin sacar una versión nueva cada vez: alerts de cristal, banners, toasts, sheets construidos con bloques desde el servidor y pantalla completa, con acciones, disparadores, frecuencia e impresiones. Habla con el hub de Appwrite (`remote-hub`) por REST. No tiene dependencias.

- iOS 26+ (y macOS 26+ para el admin). Swift 6.
- Liquid Glass nativo: el alert y el banner son `.glassEffect`, los botones `.glass`/`.glassProminent`, y todo va agrupado en `GlassEffectContainer`.
- El hub decide **a quién** y **cuántas veces**. La app decide **en qué momento** (disparadores).

## Instalación

Xcode → *File* → *Add Package Dependencies…* → `https://github.com/gabrisp/MessageKitPackage.git` → producto **MessagesKit**.

O en un `Package.swift`:

```swift
.package(url: "https://github.com/gabrisp/MessageKitPackage.git", branch: "main"),
// …
.product(name: "MessagesKit", package: "MessageKitPackage"),
```

Mientras se desarrolla junto al hub y al admin, también vale como dependencia local (*Add Local…*).

## Integración (ReWearly de ejemplo)

```swift
import MessagesKit

extension MessagesTheme {
    static let rewearly = MessagesTheme(
        colors: ["accent": .purple, "background": Color("Background")],
        fontDesign: .rounded,
        cardRadius: 34,
        glassTint: .purple.opacity(0.08)
    )
}

// Al arrancar (App.init o el primer .task):
Messages.configure(.init(
    appId: "rewearly",
    endpoint: URL(string: "http://api-endpoint.com")!,
    projectId: "remote-hub",
    publicKey: "pk_…",                               // la de la app en el admin → Apps
    userId: { await identity.id() },                 // el mismo id de RevenueCat y PostHog
    attributes: { ["isPro": gate.isPro, "garmentCount": closet.count, "onboardingCompleted": onboarding.done] },
    theme: .rewearly,
    analytics: { name, props in Analytics.track(name, props) }
))

// Lo que la app sabe abrir por nombre (acción `route`). Tiene que coincidir con lo declarado en el admin.
Messages.register(route: "paywall") { params in router.showPaywall(source: params["source"]) }
Messages.register(route: "editWorkout") { params in router.edit(id: params["id"]) }
Messages.register(action: "claimGift") { payload in gifts.claim(payload["kind"]?.stringValue) }

// Una vez, en la raíz:
RootView().messagesLayer()

// Disparadores:
ClosetScreen().messagePlacement("closet")      // pantalla
Messages.event("tryon_succeeded")              // evento (o reenvía aquí los de tu wrapper de analítica)
Messages.suppress(true)                        // durante el onboarding o una compra; false al acabar
await Messages.refresh()                       // p. ej. al hacerse Pro
Messages.userDidChange()                       // si cambia el id del usuario
```

### Pushes

```swift
// AppDelegate
func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    Messages.registerDeviceToken(token)        // detecta sandbox (build de Xcode) o producción (TestFlight y App Store)
}

// UNUserNotificationCenterDelegate
func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
    await MainActor.run { Messages.handleNotification(r.notification.request.content.userInfo) }
}
```

El permiso de avisos lo puede pedir una campaña (acción `requestPushPermission`). Si ya lo tenías, llama a `registerForRemoteNotifications()` como siempre y pásale el token a `registerDeviceToken`.

### Depuración

`MessagesDebugView()` muestra las campañas que el hub le ha servido a este usuario (y deja forzar una), los ejemplos en modo prueba, un campo para pegar un JSON y un botón para borrar el estado local. Con `debugLogging: true` en la configuración se registran en consola las decisiones del paquete.

## Cómo decide

1. Al abrir, pide las campañas al hub (función `messages`), con un tope de 4 s. Si no llegan, usa la caché del disco.
2. El hub filtra por audiencia, calendario, frecuencia (mirando `impressions`), silencio tras instalar, tope diario y capacidades: solo sirve campañas cuyas rutas y acciones propias ha registrado la app.
3. La app espera a su disparador (`launch`, `foreground`, `screen`, `event`), aplica el retraso y vuelve a comprobar la frecuencia en local (lo que acabas de ver no vuelve a salir aunque el hub tarde en enterarse).
4. Presentador único con cola: nunca hay dos mensajes a la vez, sale antes el de mayor prioridad, y nunca aparece encima de algo que la app tenga presentado.
5. Las impresiones (`shown`, `dismissed`, `clicked`, `push_opened`) se guardan en disco, se mandan en lotes a la función `events` y además se pasan al cierre `analytics` (`message_shown`, `message_clicked`…).

## Esquema

Una campaña es JSON con `schemaVersion`. El contenido va por idioma (`content: { "es": [bloques], "en": [bloques] }`); si falta el del usuario, se usa `defaultLanguage`. Los bloques y acciones que no conoce se ignoran, no rompen. Hay un ejemplo de cada presentación en `Sources/MessagesKit/Resources/Examples/`.

| Bloque | Campos |
|---|---|
| `heading` | `text`, `size` (`large`/`medium`), `align` |
| `text` | `text` (markdown: negrita, cursiva, enlaces), `style` (`body`/`secondary`/`caption`), `align` |
| `image` | `url`, `aspectRatio`, `corner`, `fit` (`fill`/`fit`), `alt` |
| `icon` | `symbol`, `tint`, `size` |
| `list` | `items: [{symbol, text, tint}]`, `tint` |
| `stat` | `value`, `label`, `tint` |
| `badge` | `text`, `tint` |
| `spacer` | `height` |
| `divider` | — |
| `button` | `title`, `style` (`primary`/`secondary`/`glass`/`destructive`/`link`), `symbol`, `action` |
| `buttonRow` | `buttons` |
| `countdown` | `until`, `label`, `expiredText` |
| `web` | `url` (https), `height` |

Colores por token (`accent`, `primaryText`, `secondaryText`, `background`, `positive`, `warning`, `danger`, o los que definas), o hex.

**Acciones** (`action.type`): `dismiss`, `route` (`name`, `params`), `deepLink` (`url`), `openURL` (`url`, `inApp`), `requestReview`, `requestPushPermission`, `share` (`text`, `url`), `copy` (`text`, `toast`), `openCampaign` (`campaignId`), `track` (`event`, `properties`), `custom` (`name`, `payload`). Todas admiten `thenDismiss` y `trackAs`.

**Presentación**: `type` (`alert`/`banner`/`toast`/`sheet`/`fullscreen`), `position` (banner y toast), `autoDismissSeconds`, `tapAction` y `detents` (sheet). Los detents son los del sistema (`"medium"`, `"large"`) y los propios (`"fitted"`, que mide el contenido, `{ "fraction": 0.4 }` y `{ "height": 320 }`). El primero es la altura con la que se abre.

Las reglas de audiencia, calendario y frecuencia están en `Schema/Rules.swift`. El hub las implementa igual en TypeScript, y `Tests/…/SharedFixtureTests.swift` comprueba que ambos lados deciden lo mismo sobre los mismos casos (`functions/shared/test/rules-cases.json`). Ese test solo corre si el paquete está junto a la carpeta `functions/` del hub; en este repo suelto se salta.

## Para el admin (vista previa)

- `Messages.preview(campaign:language:variant:theme:)`: la presenta de verdad en modo prueba.
- `MessageInlinePreview`: la pinta dentro de un marco.
- `MessageBlockPreview`: un bloque suelto.
- `MessagesTheme(spec:)`: el tema desde `apps.theme`.
- `CampaignValidator`: comprueba la campaña antes de publicar.
- `ActionDescriber`: describe lo que haría una acción.
- `presenter.testDestinationContent`: pinta a dónde llevaría una acción (rutas, deep links…) en modo prueba.
