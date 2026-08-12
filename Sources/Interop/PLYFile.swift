import Foundation
internal import PLY

/// Why a read was refused, one case per rejection the parser can make, so a
/// test can pin the exact refusal and a caller can tell a missing file from
/// a malformed one. The message carries the offending line or path.
public struct PLYReadError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case unreadable
        case badMagic
        case badFormat
        case badHeader
        case unknownType
        case listCountNotIntegral
        case propertyOutsideElement
        case duplicateProperty
        case truncated
        case malformedLine
        /// Thrown by `positions()`, not the parser: no `vertex` element
        /// with scalar `x`, `y`, `z` -- the generic parse itself never
        /// requires one.
        case noVertexPositions
    }

    public let kind: Kind
    public let message: String
}

/// A parsed PLY file as Swift values: the declared layout in full, every
/// scalar property as a column of `Double` -- lossless, because PLY's
/// integer types are 32 bits or narrower and its floating types are IEEE 754
/// already -- and list properties preserved by layout and per-instance
/// count, their values a recorded deferral.
///
/// The parsing lives in the `PLY` C++ target behind a pure C header, and
/// nothing with a C or C++ lifetime survives this initializer: every column
/// is copied into a Swift array and the parser is freed before it returns.
public struct PLYFile: Sendable {
    public enum Encoding: Sendable {
        case ascii
        case binaryLittleEndian
        case binaryBigEndian
    }

    /// One scalar type tag whichever of its two header spellings
    /// (`uchar` / `uint8`) declared it.
    public enum ScalarType: String, Sendable, Equatable {
        case int8, uint8, int16, uint16, int32, uint32, float32, float64
    }

    public struct Property: Equatable, Sendable {
        public let name: String
        public let valueType: ScalarType

        /// `nil` for a scalar property; a list property's count type.
        public let listCountType: ScalarType?

        public init(name: String, valueType: ScalarType, listCountType: ScalarType? = nil) {
            self.name = name
            self.valueType = valueType
            self.listCountType = listCountType
        }
    }

    public struct Element: Sendable {
        public let name: String
        public let count: Int
        public let properties: [Property]

        /// Parallel to `properties`; a list property's slot is `nil`.
        private let columns: [[Double]?]

        /// Parallel to `properties`; a scalar property's slot is `nil`.
        private let entryCounts: [[Int]?]

        init(name: String, count: Int, properties: [Property], columns: [[Double]?], entryCounts: [[Int]?]) {
            self.name = name
            self.count = count
            self.properties = properties
            self.columns = columns
            self.entryCounts = entryCounts
        }

        /// A scalar property's instances, `count` of them in file order;
        /// `nil` when no scalar property has that name.
        public func column(_ property: String) -> [Double]? {
            properties.firstIndex { $0.name == property }.flatMap { columns[$0] }
        }

        /// A list property's per-instance entry counts; `nil` when no list
        /// property has that name.
        public func listEntryCounts(_ property: String) -> [Int]? {
            properties.firstIndex { $0.name == property }.flatMap { entryCounts[$0] }
        }
    }

    public let encoding: Encoding

    /// `comment` and `obj_info` header lines, verbatim including their
    /// keyword, in header order.
    public let comments: [String]

    /// Every declared element, in header order, zero-instance elements
    /// included.
    public let elements: [Element]

    public func element(_ name: String) -> Element? {
        elements.first { $0.name == name }
    }

    /// The conventional cloud: the `vertex` element's scalar `x`, `y`, `z`
    /// zipped into positions. Throws when the file, however valid, has no
    /// such element -- absence is the caller's problem, not a parse error.
    public func positions() throws -> [SIMD3<Double>] {
        guard let vertex = element("vertex"),
              let x = vertex.column("x"),
              let y = vertex.column("y"),
              let z = vertex.column("z") else {
            throw PLYReadError(
                kind: .noVertexPositions,
                message: "no vertex element with scalar x, y, z"
            )
        }
        return (0..<vertex.count).map { SIMD3(x[$0], y[$0], z[$0]) }
    }

    public init(contentsOf url: URL) throws {
        let parser = ply_parse_file(url.path(percentEncoded: false))
        // The handle owns every buffer read below; nothing borrowed from it
        // outlives this initializer.
        defer { ply_free(parser) }

        let status = ply_status_of(parser)
        guard status == PLY_OK else {
            throw PLYReadError(
                kind: Self.kind(of: status),
                message: String(cString: ply_error_message(parser))
            )
        }

        switch ply_file_encoding(parser) {
        case PLY_BINARY_LITTLE_ENDIAN: encoding = .binaryLittleEndian
        case PLY_BINARY_BIG_ENDIAN: encoding = .binaryBigEndian
        default: encoding = .ascii
        }

        comments = (0..<ply_comment_count(parser)).map {
            String(cString: ply_comment(parser, $0))
        }

        elements = (0..<ply_element_count(parser)).map { elementIndex in
            let instanceCount = Int(ply_instance_count(parser, elementIndex))
            var properties: [Property] = []
            var columns: [[Double]?] = []
            var entryCounts: [[Int]?] = []
            for propertyIndex in 0..<ply_property_count(parser, elementIndex) {
                let isList = ply_property_is_list(parser, elementIndex, propertyIndex) == 1
                properties.append(Property(
                    name: String(cString: ply_property_name(parser, elementIndex, propertyIndex)),
                    valueType: Self.scalarType(of: ply_property_value_type(parser, elementIndex, propertyIndex)),
                    listCountType: isList
                        ? Self.scalarType(of: ply_property_count_type(parser, elementIndex, propertyIndex))
                        : nil
                ))
                if isList {
                    columns.append(nil)
                    let counts = ply_list_counts(parser, elementIndex, propertyIndex)
                    entryCounts.append(counts.map {
                        UnsafeBufferPointer(start: $0, count: instanceCount).map(Int.init)
                    } ?? [])
                } else {
                    entryCounts.append(nil)
                    let column = ply_scalar_column(parser, elementIndex, propertyIndex)
                    columns.append(column.map {
                        Array(UnsafeBufferPointer(start: $0, count: instanceCount))
                    } ?? [])
                }
            }
            return Element(
                name: String(cString: ply_element_name(parser, elementIndex)),
                count: instanceCount,
                properties: properties,
                columns: columns,
                entryCounts: entryCounts
            )
        }
    }

    private static func kind(of status: ply_status) -> PLYReadError.Kind {
        switch status {
        case PLY_ERROR_UNREADABLE: .unreadable
        case PLY_ERROR_BAD_MAGIC: .badMagic
        case PLY_ERROR_BAD_FORMAT: .badFormat
        case PLY_ERROR_UNKNOWN_TYPE: .unknownType
        case PLY_ERROR_LIST_COUNT_NOT_INTEGRAL: .listCountNotIntegral
        case PLY_ERROR_PROPERTY_OUTSIDE_ELEMENT: .propertyOutsideElement
        case PLY_ERROR_DUPLICATE_PROPERTY: .duplicateProperty
        case PLY_ERROR_TRUNCATED: .truncated
        case PLY_ERROR_MALFORMED_LINE: .malformedLine
        default: .badHeader
        }
    }

    private static func scalarType(of tag: ply_scalar) -> ScalarType {
        switch tag {
        case PLY_INT8: .int8
        case PLY_UINT8: .uint8
        case PLY_INT16: .int16
        case PLY_UINT16: .uint16
        case PLY_INT32: .int32
        case PLY_UINT32: .uint32
        case PLY_FLOAT64: .float64
        default: .float32
        }
    }
}
