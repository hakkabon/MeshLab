import Foundation
import simd

public enum MeshLengthUnit: String, Sendable, Hashable, Codable, CaseIterable {
    case meter
    case millimeter
    case centimeter
    case inch
    case foot

    public var metersPerUnit: Double {
        switch self {
        case .meter: 1
        case .millimeter: 1e-3
        case .centimeter: 1e-2
        case .inch: 0.0254
        case .foot: 0.3048
        }
    }
}

/// Named entity imported with a mesh. Node indices always use MeshLab's local
/// zero-based numbering; element indices are populated when the region has the
/// same dimension as the imported analysis mesh.
public struct MeshRegion: Sendable, Hashable, Codable {
    public let name: String
    public let dimension: Int
    public let physicalTag: Int
    public let nodeIndices: [Int]
    public let elementIndices: [Int]

    public init(
        name: String,
        dimension: Int,
        physicalTag: Int,
        nodeIndices: [Int],
        elementIndices: [Int]
    ) {
        self.name = name
        self.dimension = dimension
        self.physicalTag = physicalTag
        self.nodeIndices = nodeIndices
        self.elementIndices = elementIndices
    }
}

public struct MeshMetadata: Sendable, Hashable, Codable {
    public var sourceFormat: String?
    /// Coordinate unit declared at import time, when the source format does
    /// not encode one itself.
    public var sourceLengthUnit: MeshLengthUnit?
    /// Unit of coordinates stored in `Mesh`. Imports normalize this to meters.
    public var lengthUnit: MeshLengthUnit
    public var regions: [MeshRegion]

    public init(
        sourceFormat: String? = nil,
        sourceLengthUnit: MeshLengthUnit? = nil,
        lengthUnit: MeshLengthUnit = .meter,
        regions: [MeshRegion] = []
    ) {
        self.sourceFormat = sourceFormat
        self.sourceLengthUnit = sourceLengthUnit
        self.lengthUnit = lengthUnit
        self.regions = regions
    }

    private enum CodingKeys: String, CodingKey {
        case sourceFormat
        case sourceLengthUnit
        case lengthUnit
        case regions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceFormat = try container.decodeIfPresent(String.self, forKey: .sourceFormat)
        sourceLengthUnit = try container.decodeIfPresent(
            MeshLengthUnit.self,
            forKey: .sourceLengthUnit
        )
        lengthUnit = try container.decodeIfPresent(
            MeshLengthUnit.self,
            forKey: .lengthUnit
        ) ?? .meter
        regions = try container.decodeIfPresent([MeshRegion].self, forKey: .regions) ?? []
    }
}

public struct MeshImportResult: Sendable {
    public let mesh: Mesh
    public let metadata: MeshMetadata

    public init(mesh: Mesh, metadata: MeshMetadata) {
        self.mesh = mesh
        self.metadata = metadata
    }
}

public struct GmshImportOptions: Sendable, Hashable {
    /// Unit used by coordinates in the source file. Gmsh itself does not encode
    /// units; coordinates are converted to meters during import.
    public var sourceLengthUnit: MeshLengthUnit

    public init(sourceLengthUnit: MeshLengthUnit = .meter) {
        self.sourceLengthUnit = sourceLengthUnit
    }
}

public enum GmshImportError: Error, Equatable, Sendable {
    case invalidUTF8
    case missingMeshFormat
    case unsupportedVersion(String)
    case binaryNotSupported
    case malformedSection(String)
    case duplicateNode(Int)
    case missingNode(Int)
    case noSupportedElements
    case mesh(MeshError)
}

/// Imports ASCII Gmsh 2.2 and 4.1 files.
///
/// Linear triangle (type 2) and tetrahedron (type 4) elements are supported.
/// When a file contains both boundary triangles and tetrahedra, the highest
/// dimensional elements become the analysis mesh and lower-dimensional
/// physical groups remain available as named node regions.
public enum GmshImporter {
    public static func decode(
        _ data: Data,
        options: GmshImportOptions = GmshImportOptions()
    ) throws -> MeshImportResult {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GmshImportError.invalidUTF8
        }
        return try decode(text, options: options)
    }

    public static func decode(
        _ text: String,
        options: GmshImportOptions = GmshImportOptions()
    ) throws -> MeshImportResult {
        let format = try section(named: "MeshFormat", in: text)
        guard let header = format.first?.split(whereSeparator: { $0.isWhitespace }),
              header.count >= 2 else {
            throw GmshImportError.missingMeshFormat
        }
        let version = String(header[0])
        guard header[1] == "0" else { throw GmshImportError.binaryNotSupported }

        let names = parsePhysicalNames(in: text)
        let parsed: ParsedMesh
        if version.hasPrefix("2.") {
            parsed = try parseVersion2(text)
        } else if version.hasPrefix("4.1") {
            parsed = try parseVersion4(text)
        } else {
            throw GmshImportError.unsupportedVersion(version)
        }
        return try buildResult(
            parsed,
            names: names,
            sourceFormat: "gmsh-\(version)",
            options: options
        )
    }

    private struct PhysicalKey: Hashable {
        let dimension: Int
        let tag: Int
    }

    private struct ParsedElement {
        let identifier: Int
        let dimension: Int
        let nodes: [Int]
        let physicalTags: [Int]
    }

    private struct ParsedMesh {
        var nodes: [Int: SIMD3<Double>]
        var elements: [ParsedElement]
    }

    private static func parsePhysicalNames(in text: String) -> [PhysicalKey: String] {
        guard let lines = try? section(named: "PhysicalNames", in: text),
              let count = lines.first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
        else { return [:] }
        var result: [PhysicalKey: String] = [:]
        for line in lines.dropFirst().prefix(count) {
            let parts = line.split(separator: "\"", maxSplits: 2, omittingEmptySubsequences: false)
            guard let prefix = parts.first,
                  parts.count >= 2 else { continue }
            let numbers = prefix.split(whereSeparator: { $0.isWhitespace })
            guard numbers.count >= 2,
                  let dimension = Int(numbers[0]),
                  let tag = Int(numbers[1]) else { continue }
            result[PhysicalKey(dimension: dimension, tag: tag)] = String(parts[1])
        }
        return result
    }

    private static func parseVersion2(_ text: String) throws -> ParsedMesh {
        let nodeLines = try section(named: "Nodes", in: text)
        guard let count = nodeLines.first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
            throw GmshImportError.malformedSection("Nodes")
        }
        var nodes: [Int: SIMD3<Double>] = [:]
        guard nodeLines.count >= count + 1 else {
            throw GmshImportError.malformedSection("Nodes")
        }
        for line in nodeLines.dropFirst().prefix(count) {
            let values = line.split(whereSeparator: { $0.isWhitespace })
            guard values.count >= 4,
                  let tag = Int(values[0]),
                  let x = Double(values[1]),
                  let y = Double(values[2]),
                  let z = Double(values[3]) else {
                throw GmshImportError.malformedSection("Nodes")
            }
            guard nodes.updateValue(SIMD3(x, y, z), forKey: tag) == nil else {
                throw GmshImportError.duplicateNode(tag)
            }
        }

        let elementLines = try section(named: "Elements", in: text)
        guard let elementCount = elementLines.first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
            throw GmshImportError.malformedSection("Elements")
        }
        var elements: [ParsedElement] = []
        guard elementLines.count >= elementCount + 1 else {
            throw GmshImportError.malformedSection("Elements")
        }
        for line in elementLines.dropFirst().prefix(elementCount) {
            let values = line.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
            guard values.count >= 3 else {
                throw GmshImportError.malformedSection("Elements")
            }
            let type = values[1]
            let tagCount = values[2]
            guard values.count >= 3 + tagCount else {
                throw GmshImportError.malformedSection("Elements")
            }
            let element: (dimension: Int, nodeCount: Int)? = switch type {
            case 2: (2, 3)
            case 4: (3, 4)
            default: nil
            }
            guard let element else { continue }
            let nodeStart = 3 + tagCount
            guard values.count >= nodeStart + element.nodeCount else {
                throw GmshImportError.malformedSection("Elements")
            }
            let physical = tagCount > 0 ? [values[3]] : []
            elements.append(ParsedElement(
                identifier: values[0],
                dimension: element.dimension,
                nodes: Array(values[nodeStart..<(nodeStart + element.nodeCount)]),
                physicalTags: physical
            ))
        }
        return ParsedMesh(nodes: nodes, elements: elements)
    }

    private static func parseVersion4(_ text: String) throws -> ParsedMesh {
        let entityPhysicalTags = parseVersion4Entities(text)
        let nodeTokens = try section(named: "Nodes", in: text)
            .joined(separator: " ").split(whereSeparator: { $0.isWhitespace })
        var cursor = 0
        func nextInt() throws -> Int {
            guard cursor < nodeTokens.count, let value = Int(nodeTokens[cursor]) else {
                throw GmshImportError.malformedSection("Nodes")
            }
            cursor += 1
            return value
        }
        func nextDouble() throws -> Double {
            guard cursor < nodeTokens.count, let value = Double(nodeTokens[cursor]) else {
                throw GmshImportError.malformedSection("Nodes")
            }
            cursor += 1
            return value
        }
        let blockCount = try nextInt()
        _ = try nextInt()
        _ = try nextInt()
        _ = try nextInt()
        var nodes: [Int: SIMD3<Double>] = [:]
        for _ in 0..<blockCount {
            let dimension = try nextInt()
            _ = try nextInt()
            let parametric = try nextInt()
            let count = try nextInt()
            var tags: [Int] = []
            tags.reserveCapacity(count)
            for _ in 0..<count { tags.append(try nextInt()) }
            for tag in tags {
                let point = SIMD3(try nextDouble(), try nextDouble(), try nextDouble())
                if parametric != 0 {
                    for _ in 0..<dimension { _ = try nextDouble() }
                }
                guard nodes.updateValue(point, forKey: tag) == nil else {
                    throw GmshImportError.duplicateNode(tag)
                }
            }
        }

        let lines = try section(named: "Elements", in: text)
        guard let first = lines.first else {
            throw GmshImportError.malformedSection("Elements")
        }
        let header = first.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
        guard header.count >= 4 else {
            throw GmshImportError.malformedSection("Elements")
        }
        var lineIndex = 1
        var elements: [ParsedElement] = []
        for _ in 0..<header[0] {
            guard lineIndex < lines.count else {
                throw GmshImportError.malformedSection("Elements")
            }
            let block = lines[lineIndex].split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
            lineIndex += 1
            guard block.count >= 4 else {
                throw GmshImportError.malformedSection("Elements")
            }
            let dimension = block[0]
            let entityTag = block[1]
            let elementType = block[2]
            let count = block[3]
            let nodeCount: Int? = switch elementType {
            case 2: 3
            case 4: 4
            default: nil
            }
            for _ in 0..<count {
                guard lineIndex < lines.count else {
                    throw GmshImportError.malformedSection("Elements")
                }
                let values = lines[lineIndex].split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
                lineIndex += 1
                guard let nodeCount else { continue }
                guard values.count >= nodeCount + 1 else {
                    throw GmshImportError.malformedSection("Elements")
                }
                elements.append(ParsedElement(
                    identifier: values[0],
                    dimension: dimension,
                    nodes: Array(values[1...(nodeCount)]),
                    physicalTags: entityPhysicalTags[PhysicalKey(
                        dimension: dimension,
                        tag: entityTag
                    )] ?? []
                ))
            }
        }
        return ParsedMesh(nodes: nodes, elements: elements)
    }

    private static func parseVersion4Entities(_ text: String) -> [PhysicalKey: [Int]] {
        guard let lines = try? section(named: "Entities", in: text),
              let first = lines.first else { return [:] }
        let counts = first.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
        guard counts.count == 4 else { return [:] }
        var line = 1
        var result: [PhysicalKey: [Int]] = [:]
        for dimension in 0...3 {
            for _ in 0..<counts[dimension] {
                guard line < lines.count else { return result }
                let values = lines[line].split(whereSeparator: { $0.isWhitespace })
                line += 1
                let coordinateCount = dimension == 0 ? 3 : 6
                let physicalCountIndex = 1 + coordinateCount
                guard values.count > physicalCountIndex,
                      let tag = Int(values[0]),
                      let physicalCount = Int(values[physicalCountIndex]),
                      values.count >= physicalCountIndex + 1 + physicalCount else { continue }
                let tags = values[(physicalCountIndex + 1)..<(physicalCountIndex + 1 + physicalCount)]
                    .compactMap { Int($0) }
                result[PhysicalKey(dimension: dimension, tag: tag)] = tags
            }
        }
        return result
    }

    private static func buildResult(
        _ parsed: ParsedMesh,
        names: [PhysicalKey: String],
        sourceFormat: String,
        options: GmshImportOptions
    ) throws -> MeshImportResult {
        guard let dimension = parsed.elements.map(\.dimension).max(), dimension >= 2 else {
            throw GmshImportError.noSupportedElements
        }
        let selected = parsed.elements.filter { $0.dimension == dimension }
        guard !selected.isEmpty else { throw GmshImportError.noSupportedElements }
        let usedTags = Set(selected.flatMap(\.nodes))
        let orderedTags = usedTags.sorted()
        let local = Dictionary(uniqueKeysWithValues: orderedTags.enumerated().map { ($1, $0) })
        let scale = options.sourceLengthUnit.metersPerUnit
        var coordinates: [SIMD3<Double>] = []
        coordinates.reserveCapacity(orderedTags.count)
        for tag in orderedTags {
            guard let point = parsed.nodes[tag] else { throw GmshImportError.missingNode(tag) }
            coordinates.append(point * scale)
        }
        var sourceElementToLocal: [Int: Int] = [:]
        let elements = try selected.enumerated().map { index, source -> Element in
            sourceElementToLocal[source.identifier] = index
            let nodes = try source.nodes.map { tag -> Int in
                guard let value = local[tag] else { throw GmshImportError.missingNode(tag) }
                return value
            }
            return Element(
                type: dimension == 3 ? .tetrahedron4 : .triangle3,
                nodes: nodes
            )
        }
        let mesh: Mesh
        do {
            mesh = try Mesh(nodes: coordinates, elements: elements)
        } catch let error as MeshError {
            throw GmshImportError.mesh(error)
        }

        var grouped: [PhysicalKey: (nodes: Set<Int>, elements: Set<Int>)] = [:]
        for source in parsed.elements {
            for physicalTag in source.physicalTags {
                let key = PhysicalKey(dimension: source.dimension, tag: physicalTag)
                var value = grouped[key] ?? ([], [])
                for tag in source.nodes {
                    if let index = local[tag] { value.nodes.insert(index) }
                }
                if let index = sourceElementToLocal[source.identifier] {
                    value.elements.insert(index)
                }
                grouped[key] = value
            }
        }
        let regions = grouped.keys.sorted {
            $0.dimension == $1.dimension ? $0.tag < $1.tag : $0.dimension < $1.dimension
        }.map { key in
            let value = grouped[key]!
            return MeshRegion(
                name: names[key] ?? "physical-\(key.tag)",
                dimension: key.dimension,
                physicalTag: key.tag,
                nodeIndices: value.nodes.sorted(),
                elementIndices: value.elements.sorted()
            )
        }
        return MeshImportResult(
            mesh: mesh,
            metadata: MeshMetadata(
                sourceFormat: sourceFormat,
                sourceLengthUnit: options.sourceLengthUnit,
                lengthUnit: .meter,
                regions: regions
            )
        )
    }

    private static func section(named name: String, in text: String) throws -> [Substring] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "$\(name)" }),
              let end = lines[(start + 1)...].firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "$End\(name)"
              }) else {
            throw GmshImportError.malformedSection(name)
        }
        return Array(lines[(start + 1)..<end])
    }
}

/// Legacy ASCII VTK export for interoperable geometry and nodal result review.
public enum VTKLegacyExporter {
    public static func data(mesh: Mesh, result: StaticResult? = nil) -> Data {
        Data(string(mesh: mesh, result: result).utf8)
    }

    public static func string(mesh: Mesh, result: StaticResult? = nil) -> String {
        var lines = [
            "# vtk DataFile Version 3.0",
            "MeshLab export",
            "ASCII",
            "DATASET UNSTRUCTURED_GRID",
            "POINTS \(mesh.nodes.count) double",
        ]
        lines.append(contentsOf: mesh.nodes.map { "\($0.x) \($0.y) \($0.z)" })
        let cellSize = mesh.elements.reduce(0) { $0 + $1.nodes.count + 1 }
        lines.append("CELLS \(mesh.elements.count) \(cellSize)")
        lines.append(contentsOf: mesh.elements.map { element in
            "\(element.nodes.count) " + element.nodes.map(String.init).joined(separator: " ")
        })
        lines.append("CELL_TYPES \(mesh.elements.count)")
        lines.append(contentsOf: mesh.elements.map {
            $0.type == .tetrahedron4 ? "10" : "5"
        })
        if let result {
            lines.append("POINT_DATA \(mesh.nodes.count)")
            lines.append("VECTORS displacement double")
            lines.append(contentsOf: result.displacements.map { "\($0.x) \($0.y) \($0.z)" })
            lines.append("SCALARS von_mises double 1")
            lines.append("LOOKUP_TABLE default")
            lines.append(contentsOf: result.nodalVonMises.map { String($0) })
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
