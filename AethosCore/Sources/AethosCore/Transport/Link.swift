import Foundation

public protocol Link {
    func send(_ frame: Frame) throws
    func receive() throws -> Frame?
}
