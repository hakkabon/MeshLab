import Foundation
import MeshLab
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let gmshMesh = UTType(importedAs: "org.gmsh.msh", conformingTo: .plainText)
    static let legacyVTK = UTType(exportedAs: "org.vtk.legacy", conformingTo: .plainText)
}

struct VTKDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.legacyVTK] }
    static var writableContentTypes: [UTType] { [.legacyVTK] }

    var data: Data

    init(mesh: Mesh, result: StaticResult?) {
        data = VTKLegacyExporter.data(mesh: mesh, result: result)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct MeshLabProjectDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var project: MeshLabProject

    init(project: MeshLabProject) {
        self.project = project
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        project = try MeshLabProjectFile.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try MeshLabProjectFile.encode(project))
    }
}

struct ResultsCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
