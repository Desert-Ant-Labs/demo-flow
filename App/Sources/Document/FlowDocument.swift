import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A Flow file: the flow's YAML, with its own extension so it opens here.
    static let flow = UTType(exportedAs: "com.desertant.flow", conformingTo: .yaml)
}

/// One flow, as a document: its own window, saved as YAML.
struct FlowDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.flow, .yaml]
    static let writableContentTypes: [UTType] = [.flow, .yaml]

    var graph: Graph

    init(graph: Graph = Graph()) {
        self.graph = graph
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        graph = try FlowFile.read(String(decoding: data, as: UTF8.self))
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(FlowFile.write(graph).utf8))
    }
}
