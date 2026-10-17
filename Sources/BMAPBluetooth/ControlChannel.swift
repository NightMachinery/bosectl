// What the CLI needs from a BMAP session, whichever transport carries it.

import BMAP
import Foundation

/// A BMAP control session: over RFCOMM (`Session`) or Bluetooth LE
/// (`LESession`).
public protocol ControlChannel: Requester {
    /// Every packet sent and received, in order, for --trace and `raw`.
    var onTraffic: ((_ outgoing: Bool, _ packet: Packet) -> Void)? { get set }
    /// The headphones closed the channel (or the link dropped).
    var isClosed: Bool { get }
    /// Sends without waiting for an answer.
    func send(_ packet: Packet) throws
    /// Collects every packet that arrives within `duration`.
    func listen(for duration: TimeInterval) -> [Packet]
    func close()
}

extension Session: ControlChannel {}
extension LESession: ControlChannel {}
