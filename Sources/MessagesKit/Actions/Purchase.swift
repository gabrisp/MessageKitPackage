import StoreKit

/// Lo que pide una acción `purchase`. Con RevenueCat: `offering` (vacío = el actual) y
/// `packageId`; sin RevenueCat: `productId` del App Store.
public struct PurchaseRequest: Sendable, Hashable {
    public var productId: String?
    public var offering: String?
    public var packageId: String?
}

/// Cómo acabó una compra lanzada desde un mensaje.
public enum PurchaseOutcome: String, Sendable {
    case purchased, cancelled, pending, failed
}

enum StoreKitPurchase {
    /// Compra con StoreKit 2 (la hoja de Apple) cuando la app no registra su propio manejador.
    @MainActor
    static func buy(productId: String) async -> PurchaseOutcome {
        do {
            guard let product = try await Product.products(for: [productId]).first else {
                MessagesLog.error("Producto no encontrado en el App Store: \(productId)")
                return .failed
            }
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification { await transaction.finish() }
                return .purchased
            case .userCancelled: return .cancelled
            case .pending: return .pending
            @unknown default: return .failed
            }
        } catch {
            MessagesLog.error("Compra fallida: \(error.localizedDescription)")
            return .failed
        }
    }
}
