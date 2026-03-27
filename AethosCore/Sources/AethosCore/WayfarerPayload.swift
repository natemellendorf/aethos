import Foundation

public enum WayfarerPayloadOutcome: String, Sendable {
    case acceptDisplay = "accept/display"
    case acceptStoreNoDisplay = "accept/store-no-display"
    case unsupportedSafeSkip = "unsupported-safe-skip"
}

public struct WayfarerChatPayload: Equatable, Sendable {
    public let text: String
    public let createdAtUnixMs: Int64

    public init(text: String, createdAtUnixMs: Int64) {
        self.text = text
        self.createdAtUnixMs = createdAtUnixMs
    }
}

public struct WayfarerMediaAsset: Equatable, Sendable {
    public let assetRef: String
    public let mimeType: String
    public let byteLength: Int64
    public let name: String?

    public init(assetRef: String, mimeType: String, byteLength: Int64, name: String?) {
        self.assetRef = assetRef
        self.mimeType = mimeType
        self.byteLength = byteLength
        self.name = name
    }
}

public struct WayfarerMediaManifestPayload: Equatable, Sendable {
    public let transferRef: String
    public let mediaKind: String
    public let assets: [WayfarerMediaAsset]
    public let caption: String?
    public let createdAtUnixMs: Int64

    public init(
        transferRef: String,
        mediaKind: String,
        assets: [WayfarerMediaAsset],
        caption: String?,
        createdAtUnixMs: Int64
    ) {
        self.transferRef = transferRef
        self.mediaKind = mediaKind
        self.assets = assets
        self.caption = caption
        self.createdAtUnixMs = createdAtUnixMs
    }
}

public enum WayfarerPayloadClassification: Equatable, Sendable {
    case chat(WayfarerChatPayload)
    case mediaManifest(WayfarerMediaManifestPayload)
    case reserved(type: String)
    case unsupported(type: String)

    public var outcome: WayfarerPayloadOutcome {
        switch self {
        case .chat:
            return .acceptDisplay
        case .mediaManifest, .reserved:
            return .acceptStoreNoDisplay
        case .unsupported:
            return .unsupportedSafeSkip
        }
    }

    public var type: String {
        switch self {
        case .chat:
            return WayfarerPayloadCodec.chatType
        case .mediaManifest:
            return WayfarerPayloadCodec.mediaManifestType
        case .reserved(let type), .unsupported(let type):
            return type
        }
    }
}

public enum WayfarerPayloadError: Error, Equatable, Sendable {
    case invalidCBOR
    case topLevelNotMap
    case topLevelKeyNotText
    case missingType
    case nonTextType
    case malformedChat
    case malformedMediaManifest
}

public enum WayfarerPayloadCodec {
    public static let chatType = "wayfarer.chat.v1"
    public static let mediaManifestType = "wayfarer.media_manifest.v1"

    public static let reservedTypes: Set<String> = [
        "wayfarer.profile.v1",
        "wayfarer.reaction.v1",
        "wayfarer.message_update.v1",
        "wayfarer.status_event.v1",
        "wayfarer.notice.v1",
    ]

    private static let supportedMediaKinds: Set<String> = ["image", "video", "audio", "file"]

    public static func classify(body: Data) throws -> WayfarerPayloadClassification {
        let decoded: CanonicalCBORValue
        do {
            decoded = try CanonicalCBORDecoder().decode(body)
        } catch {
            throw WayfarerPayloadError.invalidCBOR
        }

        guard case .map(let entries) = decoded else {
            throw WayfarerPayloadError.topLevelNotMap
        }

        var object: [String: CanonicalCBORValue] = [:]
        for entry in entries {
            guard case .text(let key) = entry.key else {
                throw WayfarerPayloadError.topLevelKeyNotText
            }
            object[key] = entry.value
        }

        guard let typeValue = object["type"] else {
            throw WayfarerPayloadError.missingType
        }
        guard case .text(let type) = typeValue else {
            throw WayfarerPayloadError.nonTextType
        }

        switch type {
        case chatType:
            return .chat(try decodeChat(object))
        case mediaManifestType:
            return .mediaManifest(try decodeMediaManifest(object))
        default:
            if reservedTypes.contains(type) {
                return .reserved(type: type)
            }
            return .unsupported(type: type)
        }
    }

    public static func chatText(body: Data) -> String? {
        guard case .chat(let payload) = try? classify(body: body) else {
            return nil
        }
        return payload.text
    }

    private static func decodeChat(_ object: [String: CanonicalCBORValue]) throws -> WayfarerChatPayload {
        guard case .text(let text)? = object["text"], !text.isEmpty,
              let createdAtUnixMs = extractInt64(object["created_at_unix_ms"])
        else {
            throw WayfarerPayloadError.malformedChat
        }

        return WayfarerChatPayload(text: text, createdAtUnixMs: createdAtUnixMs)
    }

    private static func decodeMediaManifest(_ object: [String: CanonicalCBORValue]) throws -> WayfarerMediaManifestPayload {
        guard case .text(let transferRef)? = object["transfer_ref"], !transferRef.isEmpty,
              case .text(let mediaKind)? = object["media_kind"], supportedMediaKinds.contains(mediaKind),
              case .array(let assetValues)? = object["assets"], !assetValues.isEmpty,
              let createdAtUnixMs = extractInt64(object["created_at_unix_ms"])
        else {
            throw WayfarerPayloadError.malformedMediaManifest
        }

        let caption: String?
        if let value = object["caption"] {
            guard case .text(let text) = value else {
                throw WayfarerPayloadError.malformedMediaManifest
            }
            caption = text
        } else {
            caption = nil
        }

        let assets = try assetValues.map(decodeAsset)
        return WayfarerMediaManifestPayload(
            transferRef: transferRef,
            mediaKind: mediaKind,
            assets: assets,
            caption: caption,
            createdAtUnixMs: createdAtUnixMs
        )
    }

    private static func decodeAsset(_ value: CanonicalCBORValue) throws -> WayfarerMediaAsset {
        guard case .map(let entries) = value else {
            throw WayfarerPayloadError.malformedMediaManifest
        }

        var object: [String: CanonicalCBORValue] = [:]
        for entry in entries {
            guard case .text(let key) = entry.key else {
                throw WayfarerPayloadError.malformedMediaManifest
            }
            object[key] = entry.value
        }

        guard case .text(let assetRef)? = object["asset_ref"], !assetRef.isEmpty,
              case .text(let mimeType)? = object["mime_type"], !mimeType.isEmpty,
              let byteLength = extractInt64(object["byte_length"]), byteLength >= 0
        else {
            throw WayfarerPayloadError.malformedMediaManifest
        }

        let name: String?
        if let value = object["name"] {
            guard case .text(let text) = value else {
                throw WayfarerPayloadError.malformedMediaManifest
            }
            name = text
        } else {
            name = nil
        }

        return WayfarerMediaAsset(assetRef: assetRef, mimeType: mimeType, byteLength: byteLength, name: name)
    }

    private static func extractInt64(_ value: CanonicalCBORValue?) -> Int64? {
        guard case .unsigned(let raw)? = value, raw <= UInt64(Int64.max) else {
            return nil
        }
        return Int64(raw)
    }
}
