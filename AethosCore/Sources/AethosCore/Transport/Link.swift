import Foundation

/// A byte-moving transport for encoded `Frame`s.
///
/// Transports are intentionally dumb: they do not perform authentication, integrity,
/// or protocol-level validation beyond moving bytes.
public protocol FrameTransport {
    func send(_ frame: Frame) throws
    func receive() throws -> Frame?
}

@available(*, deprecated, renamed: "FrameTransport")
public typealias Link = FrameTransport
