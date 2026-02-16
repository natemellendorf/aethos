import Foundation

#if canImport(Network)
import Network
#endif

/// Compile-time QUIC transport stub.
///
/// This is intentionally not implemented yet; it exists so callers can start wiring
/// transport selection and configuration without changing public APIs later.
public final class ExperimentalQuicLink: FrameTransport {
    public enum QuicError: Swift.Error, Equatable {
        case notImplemented
        case platformUnsupported
    }

    public let host: String
    public let port: UInt16
    public let localWayfarerIdHex: String?
    public let expectedRemoteWayfarerIdHex: String?

    public init(
        host: String,
        port: UInt16,
        localWayfarerIdHex: String? = nil,
        expectedRemoteWayfarerIdHex: String? = nil
    ) throws {
        #if canImport(Network)
        _ = NWEndpoint.Host(host)
        #else
        throw QuicError.platformUnsupported
        #endif

        self.host = host
        self.port = port
        self.localWayfarerIdHex = localWayfarerIdHex
        self.expectedRemoteWayfarerIdHex = expectedRemoteWayfarerIdHex
    }

    public func send(_ frame: Frame) throws {
        throw QuicError.notImplemented
    }

    public func receive() throws -> Frame? {
        throw QuicError.notImplemented
    }
}

/// Compile-time QUIC server stub (not implemented).
public final class ExperimentalQuicFrameServer: @unchecked Sendable {
    public enum ServerError: Swift.Error, Equatable {
        case notImplemented
        case platformUnsupported
    }

    public let bindHost: String
    public let port: UInt16

    public init(bindHost: String, port: UInt16) throws {
        #if canImport(Network)
        _ = NWEndpoint.Host(bindHost)
        #else
        throw ServerError.platformUnsupported
        #endif
        self.bindHost = bindHost
        self.port = port
    }

    public func start() throws {
        throw ServerError.notImplemented
    }

    public func stop() throws {
        throw ServerError.notImplemented
    }
}
