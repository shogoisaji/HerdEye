import Foundation

/// Buffer that receives arbitrary byte chunks and returns completed newline-delimited
/// lines in order.
/// Reconstructs lines correctly when they are split across chunk or UTF-8 boundaries.
struct NDJSONLineReader {
    private var buffer = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    /// Return an unfinished line at EOF if one remains. The server normally sends a
    /// newline before closing, but this is a safety net.
    mutating func flush() -> Data? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return buffer
    }
}
