// BMAP over Bluetooth LE travels in segments: each write and notification is
// one header byte, (last index << 4) | this index, then up to 19 bytes of
// the packet. A packet that fits in one segment has header 0.

public enum LESegments {
    public static let dataSize = 19

    public static func split(_ bytes: [UInt8]) -> [[UInt8]]
    {
        guard !bytes.isEmpty else { return [[0]] }
        let chunks = stride(from: 0, to: bytes.count, by: dataSize).map { Array(bytes[$0 ..< min($0 + dataSize, bytes.count)]) }
        let last = UInt8(chunks.count - 1)
        return chunks.enumerated().map { [last << 4 | UInt8($0.offset)] + $0.element }
    }
}

extension LESegments {
    /// Joins received segments back into packet bytes.
    public struct Reassembler {
        private var parts: [[UInt8]?] = []

        public init() {}

        /// The packet bytes once the last segment is in; nil while more are
        /// due, or when the segment does not fit the ones before it (then
        /// the partial packet is dropped).
        public mutating func feed(_ segment: [UInt8]) -> [UInt8]?
        {
            guard let header = segment.first else { return nil }
            let last = Int(header >> 4), index = Int(header & 0x0F)
            guard index <= last else { parts = []; return nil }
            if parts.count != last + 1 { parts = Array(repeating: nil, count: last + 1) }
            parts[index] = Array(segment.dropFirst())
            guard index == last else { return nil }
            defer { parts = [] }
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.flatMap { $0! }
        }
    }
}
