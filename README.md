# MessagesKit

Mensajes a los usuarios de tus apps (ya publicadas en el App Store) que se crean y cambian desde el servidor, sin sacar una versión nueva cada vez: alerts de cristal, banners, toasts, sheets construidos con bloques y pantalla completa, con acciones, disparadores, audiencia, frecuencia, impresiones y pushes.

- iOS 17+ y macOS 14+. Swift 6. Sin dependencias.
- En iOS 26 usa Liquid Glass nativo (`.glassEffect`, `.glass`/`.glassProminent`, `GlassEffectContainer`). En iOS 17–25 los mismos mensajes salen con materiales del sistema y botones `.borderedProminent`/`.bordered`, sin hacer nada en la app.
- Habla por REST con un hub de Appwrite (funciones `messages`, `events` y `devices`). **La app no lleva ninguna API key**: solo el `appId` y la clave pública de la app, que no es secreta.
- El hub decide **a quién** y **cuántas veces**; la app, **en qué momento** (disparadores).

## Instalación

Xcode → *File* → *Add Package Dependencies…* → `https://github.com/gabrisp/MessageKitPackage.git` → producto **MessagesKit**.

```swift
.package(url: "https://github.com/gabrisp/MessageKitPackage.git", branch: "main"),
// …
.product(name: "MessagesKit", package: "MessageKitPackage"),
```

## Integración

```swift
import MessagesKit

extension MessagesTheme {
    static let myApp = MessagesTheme(
        colors: ["accent": .purple, "background": Color("Background")],
        fontDesign: .rounded,
        cardRadius: 34,
        glassTint: .purple.opacity(0.08)
    )
}

// Al arrancar:
Messages.configure(.init(
    appId: "myapp",
    endpoint: URL(string: "http://api-endpoint.com")!,
    projectId: "your-project-id",
    publicKey: "pk_…",                               // la de la app en el admin → Apps
    userId: { await identity.id() },                 // el mismo id que usas en suscripciones y analítica
    attributes: { ["isPro": store.isPro, "itemCount": items.count, "onboardingCompleted": onboarding.done] },
    theme: .myApp,
    analytics: { name, props in Analytics.track(name, props) }
))

// Lo que la app sabe abrir por nombre (acción `route`) y sus acciones propias (`custom`).
Messages.register(route: "paywall") { params in router.showPaywall(source: params["source"]) }
Messages.register(route: "editItem") { params in router.edit(id: params["id"]) }
Messages.register(action: "claimReward") { payload in rewards.claim(payload["kind"]?.stringValue) }

// Una vez, en la raíz:
RootView().messagesLayer()

// Disparadores:
HomeScreen().messagePlacement("home")          // pantalla
Messages.event("task_completed")               // evento (o reenvía aquí los de tu wrapper de analítica)
Messages.suppress(true)                        // durante el onboarding o una compra; false al acabar
await Messages.refresh()                       // p. ej. al hacerse Pro
Messages.userDidChange()                       // si cambia el id del usuario
```

### Compras (acción `purchase`)

Un botón puede lanzar la hoja de compra de Apple. Con RevenueCat, registra una vez cómo compra la app (el paquete no depende de RevenueCat):

```swift
Messages.register(purchase: { req in
    let offerings = try await Purchases.shared.offerings()
    guard let offering = req.offering.flatMap({ offerings.offering(identifier: $0) }) ?? offerings.current,
          let package = req.packageId.flatMap({ offering.package(identifier: $0) }) ?? offering.availablePackages.first
    else { return .failed }
    return try await Purchases.shared.purchase(package: package).userCancelled ? .cancelled : .purchased
})
```

Sin manejador, compra el `productId` directamente con StoreKit 2. El resultado (`purchased`, `cancelled`, `pending` o `failed`) queda en impresiones y analítica. Al completarse la compra, la app vuelve a pedir los mensajes (por ejemplo, para que dejen de salir los de usuarios gratis). Las versiones antiguas del paquete no reciben campañas con compras.

### Atributos

Cada app manda los suyos en `attributes`: los que quiera, con el nombre que quiera (`itemCount`, `followers`, `isCreator`…). El hub no tiene un esquema fijo y evalúa las reglas contra lo que mande cada app. Además van de serie: `language`, `locale`, `country`, `appVersion`, `build`, `platform`, `osVersion`, `installDate`, `daysSinceInstall`, `pushAuthorized` y `timezone`.

### Pasar la configuración de la app al admin

Para que el admin conozca el tema, las rutas, acciones, pantallas, eventos y atributos que usa la app (y los ofrezca en sus menús), pon este botón donde quieras, por ejemplo en unos ajustes de depuración:

```swift
CopyAdminConfigButton()   // o: let json = await Messages.appReport()
```

Copia un JSON; en el admin: **Apps → botón de pegar**. Crea la app si no existe, o le añade lo que falte y le pone el tema de la app si ya existía, sin tocar lo que ya hubieras escrito. Las pantallas y eventos salen en cuanto la app los ha visto al menos una vez. No se manda nada al hub por su cuenta.

### Pushes y avisos de cambios

```swift
// AppDelegate
func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    Messages.registerDeviceToken(token)        // detecta sandbox (build de Xcode) o producción (TestFlight y App Store)
}

// Push silencioso del hub ("hay cambios"): pide los mensajes y lo nuevo sale sin reabrir la app.
func application(_ app: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
    await Messages.didReceiveRemoteNotification(userInfo) ? .newData : .noData
}

// UNUserNotificationCenterDelegate
func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
    // Con la app abierta: si es de MessagesKit, el mensaje sale dentro y no hace falta el banner.
    await Messages.willPresentNotification(n.request.content.userInfo) ? [] : [.banner, .sound]
}

func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
    await Messages.handleNotification(r.notification.request.content.userInfo)
}
```

En el target: *Signing & Capabilities* → **Push Notifications** y **Background Modes → Remote notifications**.

- **Sin conexiones abiertas.** Cuando se publica, pausa o edita una campaña, el hub manda un push silencioso a esa app. Si está abierta (o iOS la despierta), pide los mensajes y lo nuevo pasa por sus disparadores como si acabara de abrirse. iOS raciona los silenciosos (unos pocos por hora); si alguno no llega, se recoge al abrir o al volver a primer plano.
- "Enviar a un usuario" (desde el admin) sale al momento si la app está abierta.
- El permiso de avisos lo puede pedir una campaña (acción `requestPushPermission`).
- En el hub basta con una clave `.p8` de APNs del equipo (*Team Scoped*, *Sandbox & Production*): cada app que se da de alta en el admin tiene sus proveedores sola.

### Depuración

`Messages.lastSync` (o lo que devuelve `await Messages.refresh()`) dice cuándo fue la última petición al hub, con qué `userId`, cuántas campañas le tocan a este usuario o qué error hubo. `MessagesDebugView()` lo enseña arriba del todo, y además enseña las campañas que el hub le ha servido a este usuario (y deja forzar una), los ejemplos en modo prueba, el botón para copiar la configuración, un campo para pegar un JSON y un botón para borrar el estado local. Con `debugLogging: true` en la configuración, el paquete apunta en consola lo que decide.

## Cómo decide

1. Pide las campañas al hub (función `messages`) al abrir, al volver a primer plano (si hace más de 5 min) y cuando llega un push silencioso. Al abrir espera como mucho 4 s; si no, usa la caché del disco.
2. El hub filtra por:
   - audiencia (reglas y porcentaje)
   - calendario
   - frecuencia (mirando `impressions`)
   - silencio tras instalar y tope diario
   - capacidades: solo sirve campañas cuyas rutas y acciones propias ha registrado la app
3. La app espera a su disparador (`launch`, `foreground`, `screen`, `event`) y aplica el retraso. Luego vuelve a comprobar la frecuencia en local, así lo que acabas de ver no vuelve a salir aunque el hub tarde en enterarse.
4. Hay un solo presentador con cola: nunca salen dos mensajes a la vez, sale antes el de más prioridad, y nunca aparece encima de algo que la app tenga presentado. `Messages.suppress(true)` lo para del todo.
5. Las impresiones (`shown`, `dismissed`, `clicked`, `push_opened`) se guardan en disco, se mandan en lotes a `events` y además se pasan al cierre `analytics` (`message_shown`, `message_clicked`…).

**Porcentaje de audiencia.** Es un despliegue estable: cada usuario cae siempre en el mismo sitio (un hash de su id y el de la campaña). Pasar de 60 % a 80 % mantiene a los mismos 60 % y añade más, y se aplica sobre los que cumplen las reglas.

## Esquema

Una campaña es JSON con `schemaVersion`. El contenido va por idioma (`content: { "es": [bloques], "en": [bloques] }`); si falta el del usuario, se usa `defaultLanguage`. Los bloques y acciones que no conoce se ignoran, no rompen, y unas reglas de audiencia que no se entienden no le salen a nadie. Hay un ejemplo de cada presentación en `Sources/MessagesKit/Resources/Examples/`.

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

Los colores van por token (`accent`, `primaryText`, `secondaryText`, `background`, `positive`, `warning`, `danger`, o los que defina el tema) o en hex.

**Acciones** (`action.type`): `dismiss`, `route` (`name`, `params`), `deepLink` (`url`), `openURL` (`url`, `inApp`), `requestReview`, `requestPushPermission`, `share` (`text`, `url`), `copy` (`text`, `toast`), `openCampaign` (`campaignId`), `track` (`event`, `properties`), `custom` (`name`, `payload`), `purchase` (`offering`, `package`, `productId`). Todas admiten `thenDismiss` y `trackAs`.

**Presentación**:
- `type`: `alert`, `banner`, `toast`, `sheet` o `fullscreen`.
- `position` (banner y toast), `autoDismissSeconds` y `tapAction`.
- `detents` (sheet): los del sistema (`"medium"`, `"large"`) y los propios (`"fitted"`, que mide el contenido, `{ "fraction": 0.4 }` y `{ "height": 320 }`). El primero es la altura con la que se abre.

**Audiencia**: `userIds`, `percent` y `rules` (`all`/`any` anidables con condiciones `{ attr, op, value }`). Operadores: `eq`, `neq`, `in`, `nin`, `gt`, `gte`, `lt`, `lte`, `exists` y `contains`. Las versiones (`"1.10"`) se comparan como versiones.

Las reglas de audiencia, calendario y frecuencia están en `Schema/Rules.swift`. El hub las implementa igual en TypeScript, y `SharedFixtureTests` comprueba que los dos lados deciden lo mismo sobre los mismos casos (solo corre si el paquete está junto a la carpeta `functions/` del hub).

## Para el admin (vista previa)

- `Messages.preview(campaign:language:variant:theme:)`: la presenta de verdad en modo prueba; los botones dicen qué harían y no se cuenta nada.
- `MessageInlinePreview`: la pinta dentro de un marco.
- `MessageBlockPreview`: un bloque suelto.
- `presenter.testDestinationContent`: pinta a dónde llevaría una acción (rutas con sus parámetros, deep links, webs, acciones propias, avisos del sistema).
- `MessagesTheme(spec:)`, `ThemeSpec(theme:)` y `AppReport`: el tema y la configuración de la app, de ida y vuelta.
- `CampaignValidator` y `ActionDescriber`.
