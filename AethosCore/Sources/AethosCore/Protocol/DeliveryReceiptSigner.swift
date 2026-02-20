import Foundation

/// Signs and verifies DeliveryReceipts using identity keys.
public enum DeliveryReceiptSigner {
    /// Sign a receipt using the given identity manager.
    /// Returns a new receipt with the signature field populated.
    public static func sign(_ receipt: DeliveryReceipt, using identityManager: IdentityManager) throws -> DeliveryReceipt {
        let canonical = DeliveryReceiptEncoder.canonicalBytes(for: receipt)
        let signature = try identityManager.sign(canonical)

        return DeliveryReceipt(
            messageId: receipt.messageId,
            destinationWayfarerId: receipt.destinationWayfarerId,
            receivedAt: receipt.receivedAt,
            signature: signature
        )
    }

    /// Verify a receipt's signature using the destination's public identity.
    /// Returns true if the signature is valid, false otherwise.
    public static func verify(_ receipt: DeliveryReceipt, using destinationIdentity: IdentityV1) throws -> Bool {
        guard let signature = receipt.signature else {
            return false
        }

        let canonical = DeliveryReceiptEncoder.canonicalBytes(for: receipt)
        return try IdentityManager.verify(
            signature: signature,
            data: canonical,
            signingPublicKey: destinationIdentity.signingPublicKey
        )
    }

    /// Create an unsigned receipt for signing.
    public static func createUnsigned(
        messageId: Data,
        destinationWayfarerId: String,
        receivedAt: Date = Date()
    ) -> DeliveryReceipt {
        DeliveryReceipt(
            messageId: messageId,
            destinationWayfarerId: destinationWayfarerId,
            receivedAt: receivedAt,
            signature: nil
        )
    }
}
