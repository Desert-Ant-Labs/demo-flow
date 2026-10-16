import Foundation
import zlib

/// Share links, the same as the web app's: the whole flow after `?f=`, as
/// YAML deflated against a dictionary made from the examples, so a link only
/// carries what is different about a flow. Nothing is stored anywhere.
enum FlowLink {
    static let site = URL(string: "https://flow.desertant.com")!

    /// Never edit the file: every link made with it needs the same bytes to open.
    private static let dictionary: [UInt8] = {
        guard let url = Bundle.main.url(forResource: "link-dictionary", withExtension: "txt"),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return [UInt8](data)
    }()

    struct BadLink: LocalizedError {
        var errorDescription: String? { "That link could not be opened" }
    }

    static func url(for graph: Graph) -> URL {
        let yaml = Array(FlowFile.write(graph, link: true).utf8)
        let code = "." + base64url(deflate(yaml))
        return URL(string: "\(site.absoluteString)/?f=\(code)")!
    }

    /// The code in a link, from anything that holds one: the link itself, or
    /// text with a link in it.
    static func code(in text: String) -> String? {
        text.firstMatch(of: #/[?&#]f=([.\w-]+)/#).map { String($0.output.1) }
    }

    /// An example link, `?example=receipts`, names one of the examples.
    static func example(in text: String) -> String? {
        text.firstMatch(of: #/[?&#]example=([\w-]+)/#).map { String($0.output.1) }
    }

    static func graph(from code: String) throws -> Graph {
        let withDictionary = code.hasPrefix(".")
        guard let bytes = unbase64url(withDictionary ? String(code.dropFirst()) : code),
              let yaml = inflate(bytes, dictionary: withDictionary)
        else { throw BadLink() }
        return try FlowFile.read(String(decoding: yaml, as: UTF8.self))
    }

    // MARK: Raw deflate with a preset dictionary

    private static func deflate(_ input: [UInt8]) -> [UInt8] {
        var stream = z_stream()
        guard deflateInit2_(&stream, 9, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return [] }
        defer { deflateEnd(&stream) }
        _ = dictionary.withUnsafeBufferPointer { deflateSetDictionary(&stream, $0.baseAddress, uInt($0.count)) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))) + 64)
        var input = input
        let written: Int = input.withUnsafeMutableBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                stream.next_in = inBuf.baseAddress
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                zlib.deflate(&stream, Z_FINISH)
                return outBuf.count - Int(stream.avail_out)
            }
        }
        return Array(output.prefix(written))
    }

    /// The most a link may unpack to. A flow worth sharing is a few
    /// kilobytes; a link made to unpack forever stops here.
    static let maxBytes = 2 << 20

    private static func inflate(_ input: [UInt8], dictionary useDictionary: Bool) -> [UInt8]? {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        if useDictionary {
            _ = dictionary.withUnsafeBufferPointer { inflateSetDictionary(&stream, $0.baseAddress, uInt($0.count)) }
        }
        var input = input
        var result: [UInt8] = []
        var status: Int32 = Z_OK
        input.withUnsafeMutableBufferPointer { inBuf in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = uInt(inBuf.count)
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            repeat {
                chunk.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(outBuf.count)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    result += outBuf.prefix(outBuf.count - Int(stream.avail_out))
                }
            } while status == Z_OK && result.count <= maxBytes
        }
        return status == Z_STREAM_END && result.count <= maxBytes ? result : nil
    }

    private static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func unbase64url(_ text: String) -> [UInt8]? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s).map { [UInt8]($0) }
    }
}
