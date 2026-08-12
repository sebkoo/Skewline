// The Swift <-> C++ seam, deliberately C. The parser behind this header is
// C++ (parser.cpp) because PLY's element/property generality -- dozens of
// declared properties per point, three encodings -- is byte-walking work,
// but the interface is pure C so the C++ language mode stays a private fact
// of this one target: a Swift module built with C++ interoperability forces
// the mode onto every importer, and this repository's tests and probes
// should not drag a language mode along to read a file format.
//
// Ownership contract: `ply_parse_file` allocates a parser that owns every
// buffer any accessor returns; nothing is valid after `ply_free`. Columns
// cross as contiguous `double` -- lossless for every PLY scalar type, all
// of which are 32 bits or narrower or are floating point already.

#pragma once

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ply_parser ply_parser;

// Why parsing stopped. Every code is a distinct loud rejection; the Swift
// side maps them one to one and never collapses two into "bad file".
typedef enum ply_status {
    PLY_OK = 0,
    PLY_ERROR_UNREADABLE = 1,          /* the file could not be opened or read */
    PLY_ERROR_BAD_MAGIC = 2,           /* the first line is not "ply" */
    PLY_ERROR_BAD_FORMAT = 3,          /* unknown encoding or version */
    PLY_ERROR_BAD_HEADER = 4,          /* malformed declaration, or no end_header */
    PLY_ERROR_UNKNOWN_TYPE = 5,        /* a type token outside the eight scalars */
    PLY_ERROR_LIST_COUNT_NOT_INTEGRAL = 6,
    PLY_ERROR_PROPERTY_OUTSIDE_ELEMENT = 7,
    PLY_ERROR_DUPLICATE_PROPERTY = 8,  /* two properties of one element share a name */
    PLY_ERROR_TRUNCATED = 9,           /* the header promised more data than the file holds */
    PLY_ERROR_MALFORMED_LINE = 10      /* an unreadable instance: wrong or unreadable
                                          ASCII tokens, or a negative list count in
                                          either encoding */
} ply_status;

// The eight scalar types, one tag per type whichever of its two spellings
// ("uchar" or "uint8") the header used.
typedef enum ply_scalar {
    PLY_INT8 = 0,
    PLY_UINT8 = 1,
    PLY_INT16 = 2,
    PLY_UINT16 = 3,
    PLY_INT32 = 4,
    PLY_UINT32 = 5,
    PLY_FLOAT32 = 6,
    PLY_FLOAT64 = 7
} ply_scalar;

typedef enum ply_encoding {
    PLY_ASCII = 0,
    PLY_BINARY_LITTLE_ENDIAN = 1,
    PLY_BINARY_BIG_ENDIAN = 2
} ply_encoding;

// Never returns NULL: a parser that failed still carries its status and
// message, so the caller frees exactly one thing on every path.
ply_parser* ply_parse_file(const char* path);
void ply_free(ply_parser* parser);

ply_status ply_status_of(const ply_parser* parser);
const char* ply_error_message(const ply_parser* parser); /* "" when PLY_OK */

ply_encoding ply_file_encoding(const ply_parser* parser);

// `comment` and `obj_info` header lines, verbatim including their keyword,
// in header order.
size_t ply_comment_count(const ply_parser* parser);
const char* ply_comment(const ply_parser* parser, size_t index);

size_t ply_element_count(const ply_parser* parser);
const char* ply_element_name(const ply_parser* parser, size_t element);
uint64_t ply_instance_count(const ply_parser* parser, size_t element);

size_t ply_property_count(const ply_parser* parser, size_t element);
const char* ply_property_name(const ply_parser* parser, size_t element, size_t property);
int ply_property_is_list(const ply_parser* parser, size_t element, size_t property);
ply_scalar ply_property_value_type(const ply_parser* parser, size_t element, size_t property);
/* Meaningful only when ply_property_is_list. */
ply_scalar ply_property_count_type(const ply_parser* parser, size_t element, size_t property);

// A scalar property's instances as one contiguous column of
// ply_instance_count doubles; NULL when the property is a list.
const double* ply_scalar_column(const ply_parser* parser, size_t element, size_t property);

// A list property's per-instance entry counts, ply_instance_count of them;
// NULL when the property is a scalar. See ply_list_values for the values
// themselves.
const uint32_t* ply_list_counts(const ply_parser* parser, size_t element, size_t property);

// A list property's values, flattened across every instance in file
// order -- ply_list_value_count(...) of them; NULL when the property is
// a scalar. Slice per instance with the running sum of ply_list_counts.
const double* ply_list_values(const ply_parser* parser, size_t element, size_t property);

// The flattened length of ply_list_values -- the sum of every instance's
// entry count for this property. An explicit accessor so the caller
// never sums ply_list_counts itself to size a read.
size_t ply_list_value_count(const ply_parser* parser, size_t element, size_t property);

#ifdef __cplusplus
}
#endif
