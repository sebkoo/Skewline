import Testing
import Foundation
import Interop

// Every fixture is synthetic, built as a literal here and written to a temp
// file at test time -- no .ply enters the repository, and nothing derives
// from a capture. Values are exact in binary32 so equality needs no
// tolerance.

private func written(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "skewline-ply-\(UUID().uuidString).ply")
    try data.write(to: url)
    return url
}

private func parsed(_ fixture: String) throws -> PLYFile {
    try PLYFile(contentsOf: try written(Data(fixture.utf8)))
}

/// The refusal a fixture provokes, `nil` when it parses -- so a test can
/// pin the exact rejection kind without matching message prose.
private func rejection(_ fixture: Data) throws -> PLYReadError.Kind? {
    do {
        _ = try PLYFile(contentsOf: try written(fixture))
        return nil
    } catch let error as PLYReadError {
        return error.kind
    }
}

private func rejection(_ fixture: String) throws -> PLYReadError.Kind? {
    try rejection(Data(fixture.utf8))
}

/// Little- or big-endian binary PLY bytes from one description, so the two
/// endianness tests are the same fixture with the bytes swapped by
/// construction rather than two hand-typed byte strings.
private func binaryFixture(header: String, bigEndian: Bool, body: (inout BinaryBody) -> Void) -> Data {
    var writer = BinaryBody(bigEndian: bigEndian)
    body(&writer)
    return Data(header.utf8) + writer.data
}

private struct BinaryBody {
    let bigEndian: Bool
    var data = Data()

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: bigEndian ? value.bigEndian : value.littleEndian) {
            data.append(contentsOf: $0)
        }
    }

    mutating func append(_ value: Float) {
        append(value.bitPattern)
    }

    mutating func append(_ value: Double) {
        append(value.bitPattern)
    }
}

private let asciiVertexFixture = """
ply
format ascii 1.0
comment synthetic fixture
obj_info made by a test
element vertex 3
property float x
property float y
property float z
property uchar intensity
end_header
0 0.5 -1 7
1.25 2 3.5 8
-2.5 4 0.75 9
"""

private let expectedX: [Double] = [0, 1.25, -2.5]
private let expectedY: [Double] = [0.5, 2, 4]
private let expectedZ: [Double] = [-1, 3.5, 0.75]
private let expectedIntensity: [Double] = [7, 8, 9]

@Test func asciiVertexColumnsReadBackExactly() throws {
    let file = try parsed(asciiVertexFixture)
    #expect(file.encoding == .ascii)
    #expect(file.comments == ["comment synthetic fixture", "obj_info made by a test"])
    let vertex = try #require(file.element("vertex"))
    #expect(vertex.count == 3)
    #expect(vertex.properties == [
        PLYFile.Property(name: "x", valueType: .float32),
        PLYFile.Property(name: "y", valueType: .float32),
        PLYFile.Property(name: "z", valueType: .float32),
        PLYFile.Property(name: "intensity", valueType: .uint8),
    ])
    #expect(vertex.column("x") == expectedX)
    #expect(vertex.column("y") == expectedY)
    #expect(vertex.column("z") == expectedZ)
    #expect(vertex.column("intensity") == expectedIntensity)
    #expect(vertex.column("missing") == nil)
}

private func binaryVertexFixture(bigEndian: Bool) -> Data {
    let encoding = bigEndian ? "binary_big_endian" : "binary_little_endian"
    let header = """
    ply
    format \(encoding) 1.0
    element vertex 3
    property float x
    property float y
    property float z
    property uchar intensity
    end_header

    """
    return binaryFixture(header: header, bigEndian: bigEndian) { body in
        for index in 0..<3 {
            body.append(Float(expectedX[index]))
            body.append(Float(expectedY[index]))
            body.append(Float(expectedZ[index]))
            body.append(UInt8(expectedIntensity[index]))
        }
    }
}

@Test func binaryLittleEndianMatchesTheASCIIValues() throws {
    let file = try PLYFile(contentsOf: try written(binaryVertexFixture(bigEndian: false)))
    #expect(file.encoding == .binaryLittleEndian)
    let vertex = try #require(file.element("vertex"))
    #expect(vertex.column("x") == expectedX)
    #expect(vertex.column("y") == expectedY)
    #expect(vertex.column("z") == expectedZ)
    #expect(vertex.column("intensity") == expectedIntensity)
}

@Test func binaryBigEndianMatchesTheASCIIValues() throws {
    let file = try PLYFile(contentsOf: try written(binaryVertexFixture(bigEndian: true)))
    #expect(file.encoding == .binaryBigEndian)
    let vertex = try #require(file.element("vertex"))
    #expect(vertex.column("x") == expectedX)
    #expect(vertex.column("y") == expectedY)
    #expect(vertex.column("z") == expectedZ)
    #expect(vertex.column("intensity") == expectedIntensity)
}

@Test func bothTypeSpellingsDescribeTheSameLayout() throws {
    let spellings = [
        ["char", "uchar", "short", "ushort", "int", "uint", "float", "double"],
        ["int8", "uint8", "int16", "uint16", "int32", "uint32", "float32", "float64"],
    ]
    let layouts = try spellings.map { names in
        let properties = names.enumerated()
            .map { "property \($0.element) p\($0.offset)" }
            .joined(separator: "\n")
        return try parsed("""
        ply
        format ascii 1.0
        element empty 0
        \(properties)
        end_header
        """).elements[0].properties
    }
    #expect(layouts[0] == layouts[1])
    #expect(layouts[0].map(\.valueType) == [
        .int8, .uint8, .int16, .uint16, .int32, .uint32, .float32, .float64,
    ])
}

@Test func asciiListsAreCountedRetainedAndWalkedPast() throws {
    let file = try parsed("""
    ply
    format ascii 1.0
    element vertex 2
    property float x
    element face 2
    property list uchar int vertex_indices
    element tail 1
    property float marker
    end_header
    1
    2
    3 0 1 2
    4 0 1 2 3
    42.5
    """)
    let face = try #require(file.element("face"))
    #expect(face.properties == [
        PLYFile.Property(name: "vertex_indices", valueType: .int32, listCountType: .uint8),
    ])
    #expect(face.listEntryCounts("vertex_indices") == [3, 4])
    #expect(face.listValues("vertex_indices") == [0, 1, 2, 0, 1, 2, 3])
    #expect(face.column("vertex_indices") == nil)
    // The element after the lists reads back exactly: the walk stayed
    // aligned through data-dependent instance sizes.
    #expect(file.element("tail")?.column("marker") == [42.5])
}

@Test func binaryListsKeepTheWalkAligned() throws {
    let header = """
    ply
    format binary_little_endian 1.0
    element face 2
    property list uchar short vertex_indices
    element tail 1
    property double marker
    end_header

    """
    let fixture = binaryFixture(header: header, bigEndian: false) { body in
        body.append(UInt8(3))
        for value in [Int16(0), 1, 2] { body.append(value) }
        body.append(UInt8(1))
        body.append(Int16(9))
        body.append(Double(42.5))
    }
    let file = try PLYFile(contentsOf: try written(fixture))
    #expect(file.element("face")?.listEntryCounts("vertex_indices") == [3, 1])
    #expect(file.element("face")?.listValues("vertex_indices") == [0, 1, 2, 9])
    #expect(file.element("tail")?.column("marker") == [42.5])
}

@Test func binaryBigEndianListsRetainValues() throws {
    let header = """
    ply
    format binary_big_endian 1.0
    element face 2
    property list uchar short vertex_indices
    element tail 1
    property double marker
    end_header

    """
    let fixture = binaryFixture(header: header, bigEndian: true) { body in
        body.append(UInt8(3))
        for value in [Int16(0), 1, 2] { body.append(value) }
        body.append(UInt8(1))
        body.append(Int16(9))
        body.append(Double(42.5))
    }
    let file = try PLYFile(contentsOf: try written(fixture))
    #expect(file.element("face")?.listEntryCounts("vertex_indices") == [3, 1])
    #expect(file.element("face")?.listValues("vertex_indices") == [0, 1, 2, 9])
    #expect(file.element("tail")?.column("marker") == [42.5])
}

@Test func positionsZipTheVertexColumns() throws {
    let positions = try parsed(asciiVertexFixture).positions()
    #expect(positions == [
        SIMD3(0, 0.5, -1),
        SIMD3(1.25, 2, 3.5),
        SIMD3(-2.5, 4, 0.75),
    ])
}

@Test func positionsRefuseAFileWithoutVertexXYZ() throws {
    let file = try parsed("""
    ply
    format ascii 1.0
    element face 0
    property list uchar int vertex_indices
    end_header
    """)
    let error = #expect(throws: PLYReadError.self) { try file.positions() }
    #expect(error?.kind == .noVertexPositions)
}

// MARK: - The loud rejections, one fixture each

@Test func aFileThatIsNotPLYIsRefused() throws {
    #expect(try rejection("off\n8 6 0\n") == .badMagic)
}

@Test func anUnknownEncodingIsRefused() throws {
    #expect(try rejection("ply\nformat binary 1.0\nend_header\n") == .badFormat)
}

@Test func anUnknownVersionIsRefused() throws {
    #expect(try rejection("ply\nformat ascii 2.0\nend_header\n") == .badFormat)
}

@Test func aMissingFormatLineIsRefused() throws {
    #expect(try rejection("ply\nelement vertex 0\nproperty float x\nend_header\n") == .badFormat)
}

@Test func anUnknownPropertyTypeIsRefused() throws {
    #expect(try rejection("""
    ply
    format ascii 1.0
    element vertex 0
    property int64 id
    end_header
    """) == .unknownType)
}

@Test func aFloatListCountTypeIsRefused() throws {
    #expect(try rejection("""
    ply
    format ascii 1.0
    element face 0
    property list float int vertex_indices
    end_header
    """) == .listCountNotIntegral)
}

@Test func aPropertyBeforeAnyElementIsRefused() throws {
    #expect(try rejection("""
    ply
    format ascii 1.0
    property float x
    end_header
    """) == .propertyOutsideElement)
}

@Test func aDuplicatePropertyNameIsRefused() throws {
    #expect(try rejection("""
    ply
    format ascii 1.0
    element vertex 0
    property float x
    property double x
    end_header
    """) == .duplicateProperty)
}

@Test func aHeaderWithoutEndHeaderIsRefused() throws {
    #expect(try rejection("ply\nformat ascii 1.0\nelement vertex 0\n") == .badHeader)
}

@Test func anUnknownHeaderKeywordIsRefused() throws {
    #expect(try rejection("""
    ply
    format ascii 1.0
    material shiny
    end_header
    """) == .badHeader)
}

@Test func asciiDataWithMissingInstancesIsRefused() throws {
    #expect(try rejection("""
    ply
    format ascii 1.0
    element vertex 3
    property float x
    end_header
    1
    2
    """) == .truncated)
}

@Test func asciiLinesWithExtraTokensAreRefused() throws {
    #expect(try rejection("""
    ply
    format ascii 1.0
    element vertex 1
    property float x
    end_header
    1 2
    """) == .malformedLine)
}

@Test func asciiLinesWithUnreadableValuesAreRefused() throws {
    #expect(try rejection("""
    ply
    format ascii 1.0
    element vertex 1
    property float x
    end_header
    watermelon
    """) == .malformedLine)
}

@Test func truncatedBinaryDataIsRefused() throws {
    let header = """
    ply
    format binary_little_endian 1.0
    element vertex 2
    property float x
    end_header

    """
    let fixture = binaryFixture(header: header, bigEndian: false) { body in
        body.append(Float(1))
    }
    #expect(try rejection(fixture) == .truncated)
}

@Test func aBinaryListLongerThanTheFileIsRefused() throws {
    let header = """
    ply
    format binary_little_endian 1.0
    element face 1
    property list uchar float vertex_indices
    end_header

    """
    let fixture = binaryFixture(header: header, bigEndian: false) { body in
        body.append(UInt8(200))
        body.append(Float(1))
    }
    #expect(try rejection(fixture) == .truncated)
}

@Test func aNegativeBinaryListCountIsRefusedNotMisaligned() throws {
    // A signed count type is legal at the header, so a hostile file can
    // deliver a negative count. The refusal must be loud: cast unchecked,
    // the byte walk would misalign silently and return wrong columns.
    let header = """
    ply
    format binary_little_endian 1.0
    element face 1
    property list char float vertex_indices
    end_header

    """
    let fixture = binaryFixture(header: header, bigEndian: false) { body in
        body.append(Int8(-1))
    }
    #expect(try rejection(fixture) == .malformedLine)
}

@Test func anAbsurdElementCountIsRefusedNotFatal() throws {
    // UInt64.max declared instances in a ~90-byte file: the honest answer
    // is truncation, and it must arrive as a thrown error, never as a
    // C++ exception terminating the process.
    #expect(try rejection("""
    ply
    format ascii 1.0
    element vertex 18446744073709551615
    property float x
    end_header
    1
    """) == .truncated)
}

@Test func aMissingFileIsRefusedAsUnreadable() throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "skewline-ply-missing-\(UUID().uuidString).ply")
    let error = #expect(throws: PLYReadError.self) { try PLYFile(contentsOf: url) }
    #expect(error?.kind == .unreadable)
}
