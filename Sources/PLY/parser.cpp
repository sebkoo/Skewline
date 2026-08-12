// The PLY parser: header grammar, three encodings, arbitrary per-element
// property lists. Standard library only -- this target must compile
// identically on macOS and iOS, and anything it included would become a
// thing both build jobs drag along.

#include "ply.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace {

struct Property {
    std::string name;
    ply_scalar valueType = PLY_FLOAT32;
    bool isList = false;
    ply_scalar countType = PLY_UINT8;
};

struct Element {
    std::string name;
    uint64_t count = 0;
    std::vector<Property> properties;
    // Parallel to `properties`: a scalar property fills its `columns` slot;
    // a list property fills its `listCounts` slot and its `listValues`
    // slot (flattened across every instance); the unused slot stays empty.
    std::vector<std::vector<double>> columns;
    std::vector<std::vector<uint32_t>> listCounts;
    std::vector<std::vector<double>> listValues;
};

size_t scalarSize(ply_scalar type) {
    switch (type) {
    case PLY_INT8:
    case PLY_UINT8: return 1;
    case PLY_INT16:
    case PLY_UINT16: return 2;
    case PLY_INT32:
    case PLY_UINT32:
    case PLY_FLOAT32: return 4;
    case PLY_FLOAT64: return 8;
    }
    return 0;
}

bool scalarTag(const std::string& token, ply_scalar& out) {
    if (token == "char" || token == "int8") { out = PLY_INT8; return true; }
    if (token == "uchar" || token == "uint8") { out = PLY_UINT8; return true; }
    if (token == "short" || token == "int16") { out = PLY_INT16; return true; }
    if (token == "ushort" || token == "uint16") { out = PLY_UINT16; return true; }
    if (token == "int" || token == "int32") { out = PLY_INT32; return true; }
    if (token == "uint" || token == "uint32") { out = PLY_UINT32; return true; }
    if (token == "float" || token == "float32") { out = PLY_FLOAT32; return true; }
    if (token == "double" || token == "float64") { out = PLY_FLOAT64; return true; }
    return false;
}

bool isIntegral(ply_scalar type) {
    return type != PLY_FLOAT32 && type != PLY_FLOAT64;
}

bool hostIsBigEndian() {
    const uint16_t probe = 1;
    unsigned char first;
    std::memcpy(&first, &probe, 1);
    return first == 0;
}

uint64_t swapped(uint64_t value, size_t size) {
    switch (size) {
    case 2: return __builtin_bswap16(static_cast<uint16_t>(value));
    case 4: return __builtin_bswap32(static_cast<uint32_t>(value));
    case 8: return __builtin_bswap64(value);
    default: return value;
    }
}

// One scalar from raw bytes to double -- exact for every PLY type: the
// integer types are 32 bits or narrower, well inside double's 53-bit
// integer range, and the floating types are IEEE 754 already.
double decodeScalar(const unsigned char* bytes, ply_scalar type, bool swap) {
    const size_t size = scalarSize(type);
    uint64_t raw = 0;
    std::memcpy(&raw, bytes, size);
    if (swap) {
        raw = swapped(raw, size);
    }
    switch (type) {
    case PLY_INT8: return static_cast<int8_t>(raw);
    case PLY_UINT8: return static_cast<uint8_t>(raw);
    case PLY_INT16: return static_cast<int16_t>(raw);
    case PLY_UINT16: return static_cast<uint16_t>(raw);
    case PLY_INT32: return static_cast<int32_t>(raw);
    case PLY_UINT32: return static_cast<uint32_t>(raw);
    case PLY_FLOAT32: {
        const uint32_t bits = static_cast<uint32_t>(raw);
        float value;
        std::memcpy(&value, &bits, 4);
        return value;
    }
    case PLY_FLOAT64: {
        double value;
        std::memcpy(&value, &raw, 8);
        return value;
    }
    }
    return 0;
}

std::vector<std::string> tokens(const std::string& line) {
    std::vector<std::string> result;
    size_t index = 0;
    while (index < line.size()) {
        while (index < line.size() && (line[index] == ' ' || line[index] == '\t')) {
            index += 1;
        }
        const size_t start = index;
        while (index < line.size() && line[index] != ' ' && line[index] != '\t') {
            index += 1;
        }
        if (index > start) {
            result.push_back(line.substr(start, index - start));
        }
    }
    return result;
}

bool parseDouble(const std::string& token, double& out) {
    if (token.empty()) {
        return false;
    }
    char* end = nullptr;
    out = std::strtod(token.c_str(), &end);
    return end == token.c_str() + token.size();
}

bool parseCount(const std::string& token, uint64_t& out) {
    if (token.empty() || token[0] == '-') {
        return false;
    }
    char* end = nullptr;
    out = std::strtoull(token.c_str(), &end, 10);
    return end == token.c_str() + token.size();
}

} // namespace

struct ply_parser {
    ply_status status = PLY_OK;
    std::string error;
    ply_encoding encoding = PLY_ASCII;
    std::vector<std::string> comments;
    std::vector<Element> elements;

    void fail(ply_status code, const std::string& message) {
        status = code;
        error = message;
    }
};

namespace {

// The next header line: text up to '\n', a trailing '\r' stripped so CRLF
// headers parse identically. Returns false at end of buffer.
bool nextLine(const std::string& buffer, size_t& cursor, std::string& line) {
    if (cursor >= buffer.size()) {
        return false;
    }
    const size_t newline = buffer.find('\n', cursor);
    const size_t end = newline == std::string::npos ? buffer.size() : newline;
    line.assign(buffer, cursor, end - cursor);
    cursor = newline == std::string::npos ? buffer.size() : newline + 1;
    if (!line.empty() && line.back() == '\r') {
        line.pop_back();
    }
    return true;
}

// Header grammar. On success `cursor` sits on the first data byte.
void parseHeader(ply_parser& parser, const std::string& buffer, size_t& cursor) {
    std::string line;
    if (!nextLine(buffer, cursor, line) || line != "ply") {
        parser.fail(PLY_ERROR_BAD_MAGIC, "first line is not \"ply\"");
        return;
    }
    bool sawFormat = false;
    while (nextLine(buffer, cursor, line)) {
        const std::vector<std::string> words = tokens(line);
        if (words.empty()) {
            continue;
        }
        const std::string& keyword = words[0];
        if (keyword == "end_header") {
            if (!sawFormat) {
                parser.fail(PLY_ERROR_BAD_FORMAT, "no format line before end_header");
            }
            return;
        }
        if (keyword == "format") {
            if (words.size() != 3 || words[2] != "1.0") {
                parser.fail(PLY_ERROR_BAD_FORMAT, "format line is not \"format <encoding> 1.0\": " + line);
                return;
            }
            if (words[1] == "ascii") {
                parser.encoding = PLY_ASCII;
            } else if (words[1] == "binary_little_endian") {
                parser.encoding = PLY_BINARY_LITTLE_ENDIAN;
            } else if (words[1] == "binary_big_endian") {
                parser.encoding = PLY_BINARY_BIG_ENDIAN;
            } else {
                parser.fail(PLY_ERROR_BAD_FORMAT, "unknown encoding: " + words[1]);
                return;
            }
            sawFormat = true;
        } else if (keyword == "comment" || keyword == "obj_info") {
            parser.comments.push_back(line);
        } else if (keyword == "element") {
            uint64_t count = 0;
            if (words.size() != 3 || !parseCount(words[2], count)) {
                parser.fail(PLY_ERROR_BAD_HEADER, "element line is not \"element <name> <count>\": " + line);
                return;
            }
            Element element;
            element.name = words[1];
            element.count = count;
            parser.elements.push_back(std::move(element));
        } else if (keyword == "property") {
            if (parser.elements.empty()) {
                parser.fail(PLY_ERROR_PROPERTY_OUTSIDE_ELEMENT, "property before any element: " + line);
                return;
            }
            Element& element = parser.elements.back();
            Property property;
            if (words.size() == 5 && words[1] == "list") {
                if (!scalarTag(words[2], property.countType) || !scalarTag(words[3], property.valueType)) {
                    parser.fail(PLY_ERROR_UNKNOWN_TYPE, "unknown type in: " + line);
                    return;
                }
                if (!isIntegral(property.countType)) {
                    parser.fail(PLY_ERROR_LIST_COUNT_NOT_INTEGRAL, "list count type is not integral: " + line);
                    return;
                }
                property.isList = true;
                property.name = words[4];
            } else if (words.size() == 3) {
                if (!scalarTag(words[1], property.valueType)) {
                    parser.fail(PLY_ERROR_UNKNOWN_TYPE, "unknown type in: " + line);
                    return;
                }
                property.name = words[2];
            } else {
                parser.fail(PLY_ERROR_BAD_HEADER, "malformed property line: " + line);
                return;
            }
            for (const Property& existing : element.properties) {
                if (existing.name == property.name) {
                    parser.fail(PLY_ERROR_DUPLICATE_PROPERTY,
                                "element " + element.name + " declares " + property.name + " twice");
                    return;
                }
            }
            element.properties.push_back(std::move(property));
        } else {
            parser.fail(PLY_ERROR_BAD_HEADER, "unknown header keyword: " + line);
            return;
        }
    }
    parser.fail(PLY_ERROR_BAD_HEADER, "no end_header line");
}

void prepareStorage(Element& element) {
    element.columns.resize(element.properties.size());
    element.listCounts.resize(element.properties.size());
    element.listValues.resize(element.properties.size());
    // The reserve is advisory and clamped: a hostile declared count must
    // not make it throw. The vectors still grow to their true size, and
    // every append consumes file bytes, so growth is bounded by the file
    // and an absurd count falls through to the truncation rejection.
    // `listValues` gets no reserve: unlike one-count-per-instance, the
    // number of values per list property isn't known ahead of time.
    const uint64_t reserved = std::min<uint64_t>(element.count, uint64_t{1} << 20);
    for (size_t index = 0; index < element.properties.size(); index += 1) {
        if (element.properties[index].isList) {
            element.listCounts[index].reserve(reserved);
        } else {
            element.columns[index].reserve(reserved);
        }
    }
}

// ASCII data: one instance per non-blank line, token count exactly what the
// element's properties demand -- lists make that demand dynamic, so tokens
// are consumed left to right and both leftovers and shortfalls are loud.
void parseASCII(ply_parser& parser, const std::string& buffer, size_t& cursor) {
    std::string line;
    for (Element& element : parser.elements) {
        prepareStorage(element);
        for (uint64_t instance = 0; instance < element.count; instance += 1) {
            std::vector<std::string> words;
            while (words.empty()) {
                if (!nextLine(buffer, cursor, line)) {
                    parser.fail(PLY_ERROR_TRUNCATED,
                                "element " + element.name + " promises more instances than the file holds");
                    return;
                }
                words = tokens(line);
            }
            size_t token = 0;
            for (size_t index = 0; index < element.properties.size(); index += 1) {
                const Property& property = element.properties[index];
                if (property.isList) {
                    uint64_t count = 0;
                    if (token >= words.size() || !parseCount(words[token], count)) {
                        parser.fail(PLY_ERROR_MALFORMED_LINE, "unreadable list count on: " + line);
                        return;
                    }
                    token += 1;
                    if (words.size() - token < count) {
                        parser.fail(PLY_ERROR_MALFORMED_LINE, "fewer list values than counted on: " + line);
                        return;
                    }
                    double value = 0;
                    for (uint64_t entry = 0; entry < count; entry += 1) {
                        if (!parseDouble(words[token], value)) {
                            parser.fail(PLY_ERROR_MALFORMED_LINE, "unreadable value on: " + line);
                            return;
                        }
                        element.listValues[index].push_back(value);
                        token += 1;
                    }
                    element.listCounts[index].push_back(static_cast<uint32_t>(count));
                } else {
                    double value = 0;
                    if (token >= words.size() || !parseDouble(words[token], value)) {
                        parser.fail(PLY_ERROR_MALFORMED_LINE, "unreadable value on: " + line);
                        return;
                    }
                    token += 1;
                    element.columns[index].push_back(value);
                }
            }
            if (token != words.size()) {
                parser.fail(PLY_ERROR_MALFORMED_LINE, "extra tokens on: " + line);
                return;
            }
        }
    }
}

// Binary data: a bounds-checked byte walk. List values must be decoded to
// know where the next instance begins -- the layout is data-dependent --
// and now that they are decoded anyway, they are retained rather than
// discarded.
void parseBinary(ply_parser& parser, const std::string& buffer, size_t cursor) {
    const bool swap = (parser.encoding == PLY_BINARY_BIG_ENDIAN) != hostIsBigEndian();
    const unsigned char* bytes = reinterpret_cast<const unsigned char*>(buffer.data());
    size_t remaining = buffer.size() - cursor;
    const unsigned char* head = bytes + cursor;
    for (Element& element : parser.elements) {
        prepareStorage(element);
        for (uint64_t instance = 0; instance < element.count; instance += 1) {
            for (size_t index = 0; index < element.properties.size(); index += 1) {
                const Property& property = element.properties[index];
                if (property.isList) {
                    const size_t countSize = scalarSize(property.countType);
                    if (remaining < countSize) {
                        parser.fail(PLY_ERROR_TRUNCATED, "file ends inside a list count of " + element.name);
                        return;
                    }
                    // Signed count types are legal at the header, so the
                    // decoded value is checked before the cast: a negative
                    // double to uint64_t is undefined behavior, and the walk
                    // would silently misalign from there.
                    const double countValue = decodeScalar(head, property.countType, swap);
                    if (countValue < 0) {
                        parser.fail(PLY_ERROR_MALFORMED_LINE,
                                    "negative list count ("
                                        + std::to_string(static_cast<long long>(countValue))
                                        + ") in element " + element.name);
                        return;
                    }
                    const uint64_t count = static_cast<uint64_t>(countValue);
                    head += countSize;
                    remaining -= countSize;
                    const size_t valueSize = scalarSize(property.valueType);
                    if (remaining / valueSize < count) {
                        parser.fail(PLY_ERROR_TRUNCATED, "file ends inside a list of " + element.name);
                        return;
                    }
                    for (uint64_t entry = 0; entry < count; entry += 1) {
                        element.listValues[index].push_back(decodeScalar(head, property.valueType, swap));
                        head += valueSize;
                        remaining -= valueSize;
                    }
                    element.listCounts[index].push_back(static_cast<uint32_t>(count));
                } else {
                    const size_t size = scalarSize(property.valueType);
                    if (remaining < size) {
                        parser.fail(PLY_ERROR_TRUNCATED,
                                    "element " + element.name + " promises more data than the file holds");
                        return;
                    }
                    element.columns[index].push_back(decodeScalar(head, property.valueType, swap));
                    head += size;
                    remaining -= size;
                }
            }
        }
    }
    // Bytes after the last declared instance are ignored, not policed.
}

} // namespace

extern "C" {

ply_parser* ply_parse_file(const char* path) {
    ply_parser* parser = new ply_parser();
    // No exception may cross extern "C": it would bypass every caller's
    // error handling and terminate the host process. Anything thrown --
    // an allocation failure on a genuinely huge file, most plausibly --
    // becomes a status like every other refusal.
    try {
        std::ifstream stream(path, std::ios::binary);
        if (!stream.good()) {
            parser->fail(PLY_ERROR_UNREADABLE, std::string("cannot open ") + path);
            return parser;
        }
        std::string buffer((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
        if (stream.bad()) {
            parser->fail(PLY_ERROR_UNREADABLE, std::string("cannot read ") + path);
            return parser;
        }
        size_t cursor = 0;
        parseHeader(*parser, buffer, cursor);
        if (parser->status != PLY_OK) {
            return parser;
        }
        if (parser->encoding == PLY_ASCII) {
            parseASCII(*parser, buffer, cursor);
        } else {
            parseBinary(*parser, buffer, cursor);
        }
    } catch (const std::exception& exception) {
        parser->fail(PLY_ERROR_UNREADABLE, std::string("parse aborted: ") + exception.what());
    } catch (...) {
        parser->fail(PLY_ERROR_UNREADABLE, "parse aborted");
    }
    return parser;
}

void ply_free(ply_parser* parser) {
    delete parser;
}

ply_status ply_status_of(const ply_parser* parser) {
    return parser->status;
}

const char* ply_error_message(const ply_parser* parser) {
    return parser->error.c_str();
}

ply_encoding ply_file_encoding(const ply_parser* parser) {
    return parser->encoding;
}

size_t ply_comment_count(const ply_parser* parser) {
    return parser->comments.size();
}

const char* ply_comment(const ply_parser* parser, size_t index) {
    return parser->comments[index].c_str();
}

size_t ply_element_count(const ply_parser* parser) {
    return parser->elements.size();
}

const char* ply_element_name(const ply_parser* parser, size_t element) {
    return parser->elements[element].name.c_str();
}

uint64_t ply_instance_count(const ply_parser* parser, size_t element) {
    return parser->elements[element].count;
}

size_t ply_property_count(const ply_parser* parser, size_t element) {
    return parser->elements[element].properties.size();
}

const char* ply_property_name(const ply_parser* parser, size_t element, size_t property) {
    return parser->elements[element].properties[property].name.c_str();
}

int ply_property_is_list(const ply_parser* parser, size_t element, size_t property) {
    return parser->elements[element].properties[property].isList ? 1 : 0;
}

ply_scalar ply_property_value_type(const ply_parser* parser, size_t element, size_t property) {
    return parser->elements[element].properties[property].valueType;
}

ply_scalar ply_property_count_type(const ply_parser* parser, size_t element, size_t property) {
    return parser->elements[element].properties[property].countType;
}

const double* ply_scalar_column(const ply_parser* parser, size_t element, size_t property) {
    const Element& owner = parser->elements[element];
    if (owner.properties[property].isList) {
        return nullptr;
    }
    return owner.columns[property].data();
}

const uint32_t* ply_list_counts(const ply_parser* parser, size_t element, size_t property) {
    const Element& owner = parser->elements[element];
    if (!owner.properties[property].isList) {
        return nullptr;
    }
    return owner.listCounts[property].data();
}

const double* ply_list_values(const ply_parser* parser, size_t element, size_t property) {
    const Element& owner = parser->elements[element];
    if (!owner.properties[property].isList) {
        return nullptr;
    }
    return owner.listValues[property].data();
}

size_t ply_list_value_count(const ply_parser* parser, size_t element, size_t property) {
    const Element& owner = parser->elements[element];
    if (!owner.properties[property].isList) {
        return 0;
    }
    return owner.listValues[property].size();
}

} // extern "C"
