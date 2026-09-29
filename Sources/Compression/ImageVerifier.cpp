#include <algorithm>
#include <array>
#include <cerrno>
#include <csetjmp>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <iostream>
#include <limits>
#include <set>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <vector>

#include <jpeglib.h>
#include <zlib.h>

namespace fs = std::filesystem;

namespace {

constexpr uint64_t kMaximumFileBytes = 512ULL * 1024 * 1024;
constexpr uint64_t kMaximumDecodedBytes = 512ULL * 1024 * 1024;
constexpr uint64_t kMaximumWorkingBytes = 768ULL * 1024 * 1024;
constexpr uint64_t kMaximumJpegMetadataBytes = 128ULL * 1024 * 1024;
constexpr uint64_t kMaximumApp11Bytes = 16ULL * 1024 * 1024;
constexpr uint64_t kMaximumJpegCoefficientBytes = 256ULL * 1024 * 1024;
constexpr size_t kMaximumChunks = 100000;
constexpr int kMaximumJpegScans = 100;

struct Failure : std::runtime_error { using std::runtime_error::runtime_error; };

uint32_t be32(const uint8_t *p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}

uint16_t be16(const uint8_t *p) { return uint16_t((uint16_t(p[0]) << 8) | p[1]); }

std::vector<uint8_t> readFile(const fs::path &path) {
    std::error_code ec;
    const auto size = fs::file_size(path, ec);
    if (ec || size > kMaximumFileBytes) throw Failure("file unavailable or exceeds the safety limit");
    FILE *file = std::fopen(path.c_str(), "rb");
    if (!file) throw Failure("file unavailable");
    std::vector<uint8_t> data((size_t(size)));
    const bool ok = data.empty() || std::fread(data.data(), 1, data.size(), file) == data.size();
    std::fclose(file);
    if (!ok) throw Failure("file read failed");
    return data;
}

bool containsUnsafeToken(const std::vector<uint8_t> &bytes) {
    static const char *tokens[] = {"c2pa", "jumbf", "hdrgm", "gcontainer", "gainmap", "iso:ts:21496"};
    for (const char *token : tokens) {
        const size_t length = std::strlen(token);
        if (length > bytes.size()) continue;
        for (size_t start = 0; start <= bytes.size() - length; ++start) {
            size_t index = 0;
            for (; index < length; ++index) {
                uint8_t value = bytes[start + index];
                if (value >= 'A' && value <= 'Z') value = uint8_t(value + 32);
                if (value != uint8_t(token[index])) break;
            }
            if (index == length) return true;
        }
    }
    return false;
}

std::string jsonEscape(const std::string &value) {
    std::string result;
    for (unsigned char c : value) {
        if (c == '"' || c == '\\') { result.push_back('\\'); result.push_back(char(c)); }
        else if (c >= 0x20 && c < 0x7f) result.push_back(char(c));
        else result.push_back(' ');
    }
    return result;
}

struct ImageResult { std::string kind; uint32_t width = 0, height = 0; };

struct PngChunk {
    std::array<char, 4> type{};
    std::vector<uint8_t> data;
    std::string name() const { return std::string(type.data(), 4); }
};

void appendPngChunk(std::vector<uint8_t> &raw, const PngChunk &chunk) {
    const uint32_t length = uint32_t(chunk.data.size());
    raw.push_back(uint8_t(length >> 24)); raw.push_back(uint8_t(length >> 16));
    raw.push_back(uint8_t(length >> 8)); raw.push_back(uint8_t(length));
    raw.insert(raw.end(), reinterpret_cast<const uint8_t *>(chunk.type.data()),
               reinterpret_cast<const uint8_t *>(chunk.type.data()) + 4);
    raw.insert(raw.end(), chunk.data.begin(), chunk.data.end());
    uLong crc = crc32(crc32(0L, Z_NULL, 0), reinterpret_cast<const Bytef *>(chunk.type.data()), 4);
    if (!chunk.data.empty()) crc = crc32(crc, chunk.data.data(), uInt(chunk.data.size()));
    raw.push_back(uint8_t(crc >> 24)); raw.push_back(uint8_t(crc >> 16));
    raw.push_back(uint8_t(crc >> 8)); raw.push_back(uint8_t(crc));
}

struct PngImage {
    uint32_t width = 0, height = 0;
    uint8_t bitDepth = 0, colorType = 0, interlace = 0;
    std::vector<PngChunk> chunks;
    std::vector<uint8_t> samples;
    uint64_t retainedBytes() const {
        uint64_t total = samples.size() + chunks.size() * sizeof(PngChunk);
        for (const auto &chunk : chunks) total += chunk.data.size();
        return total;
    }
};

int pngChannels(uint8_t type) {
    switch (type) { case 0: return 1; case 2: return 3; case 3: return 1; case 4: return 2; case 6: return 4; default: return 0; }
}

bool validDepth(uint8_t type, uint8_t depth) {
    switch (type) {
        case 0: return depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16;
        case 2: case 4: case 6: return depth == 8 || depth == 16;
        case 3: return depth == 1 || depth == 2 || depth == 4 || depth == 8;
        default: return false;
    }
}

bool knownAncillary(const std::string &name) {
    static const std::set<std::string> names = {
        "cHRM","gAMA","iCCP","sBIT","sRGB","bKGD","hIST","tRNS","pHYs","sPLT","tIME",
        "iTXt","tEXt","zTXt","eXIf","oFFs","pCAL","sCAL","gIFg","gIFx","gIFt","sTER"
    };
    return names.count(name) != 0;
}

PngImage parsePng(const fs::path &path, bool decode = true, uint64_t retainedBase = 0, bool keepIdat = false) {
    std::error_code sizeError;
    const uint64_t inputSize = fs::file_size(path, sizeError);
    if (sizeError || inputSize > kMaximumFileBytes || retainedBase > kMaximumWorkingBytes - inputSize)
        throw Failure("PNG exceeds the cumulative memory safety limit");
    const auto bytes = readFile(path);
    static const uint8_t signature[] = {0x89,'P','N','G',0x0d,0x0a,0x1a,0x0a};
    if (bytes.size() < 8 || std::memcmp(bytes.data(), signature, 8) != 0) throw Failure("unsupported image format");
    PngImage image;
    size_t pos = 8;
    bool sawIHDR = false, sawPLTE = false, sawTRNS = false, sawIDAT = false, endedIDAT = false, sawIEND = false;
    size_t paletteEntries = 0;
    uint64_t storedChunkBytes = 0;
    while (pos < bytes.size()) {
        if (image.chunks.size() >= kMaximumChunks || bytes.size() - pos < 12) throw Failure("malformed PNG chunk stream");
        const uint32_t length = be32(bytes.data() + pos);
        if (length > 256U * 1024 * 1024 || uint64_t(pos) + 12 + length > bytes.size()) throw Failure("malformed PNG chunk length");
        PngChunk chunk;
        std::memcpy(chunk.type.data(), bytes.data() + pos + 4, 4);
        const uint64_t chunkOverhead = uint64_t(image.chunks.size() + 1) * sizeof(PngChunk);
        if (chunkOverhead > kMaximumWorkingBytes - retainedBase - bytes.size() ||
            storedChunkBytes > kMaximumWorkingBytes - retainedBase - bytes.size() - chunkOverhead ||
            length > kMaximumWorkingBytes - retainedBase - bytes.size() - chunkOverhead - storedChunkBytes)
            throw Failure("PNG exceeds the cumulative memory safety limit");
        chunk.data.assign(bytes.begin() + pos + 8, bytes.begin() + pos + 8 + length);
        storedChunkBytes += length;
        const uLong crc = crc32(crc32(0L, Z_NULL, 0), bytes.data() + pos + 4, uInt(4 + length));
        if (uint32_t(crc) != be32(bytes.data() + pos + 8 + length)) throw Failure("PNG CRC mismatch");
        const std::string name = chunk.name();
        if (image.chunks.empty() && name != "IHDR") throw Failure("PNG IHDR is not first");
        if (sawIEND) throw Failure("trailing data after PNG IEND");
        if (name == "IHDR") {
            if (sawIHDR || length != 13) throw Failure("invalid PNG IHDR");
            sawIHDR = true; image.width = be32(chunk.data.data()); image.height = be32(chunk.data.data() + 4);
            image.bitDepth = chunk.data[8]; image.colorType = chunk.data[9]; image.interlace = chunk.data[12];
            if (!image.width || !image.height || image.width > 100000 || image.height > 100000 ||
                !validDepth(image.colorType, image.bitDepth) || chunk.data[10] || chunk.data[11] || image.interlace > 1)
                throw Failure("unsupported PNG layout");
        } else if (name == "PLTE") {
            if (sawPLTE || sawIDAT || chunk.data.empty() || chunk.data.size() % 3 || chunk.data.size() > 768 ||
                image.colorType == 0 || image.colorType == 4) throw Failure("invalid PNG palette");
            sawPLTE = true; paletteEntries = chunk.data.size() / 3;
        } else if (name == "tRNS") {
            if (sawTRNS || sawIDAT ||
                (image.colorType == 0 && chunk.data.size() != 2) ||
                (image.colorType == 2 && chunk.data.size() != 6) ||
                (image.colorType == 3 && (!sawPLTE || chunk.data.size() > paletteEntries)) ||
                image.colorType == 4 || image.colorType == 6) throw Failure("invalid PNG transparency chunk");
            sawTRNS = true;
        } else if (name == "IDAT") {
            if (!sawIHDR || endedIDAT) throw Failure("non-contiguous PNG IDAT chunks");
            if (image.colorType == 3 && !sawPLTE) throw Failure("indexed PNG has no palette");
            sawIDAT = true;
        } else {
            if (sawIDAT && name != "IEND") endedIDAT = true;
            if (name == "IEND") {
                if (length || !sawIDAT) throw Failure("invalid PNG IEND");
                sawIEND = true;
            }
            if (name == "acTL" || name == "fcTL" || name == "fdAT") throw Failure("animated PNG is unsupported");
            if (name == "dSIG" || name == "caBX" || name == "iDOT") throw Failure("signed or provenance PNG is unsupported");
            if (name == "cICP" || name == "mDCv" || name == "cLLi") throw Failure("HDR PNG is unsupported");
            if (containsUnsafeToken(chunk.data)) throw Failure("signed, provenance, or HDR PNG is unsupported");
            const bool ancillary = (uint8_t(chunk.type[0]) & 0x20) != 0;
            if (!ancillary && name != "PLTE" && name != "IEND") throw Failure("unknown critical PNG chunk");
            if (ancillary && !knownAncillary(name) && (uint8_t(chunk.type[3]) & 0x20) == 0)
                throw Failure("unknown unsafe PNG chunk");
        }
        image.chunks.push_back(std::move(chunk));
        pos += 12 + length;
    }
    if (!sawIHDR || !sawIDAT || !sawIEND || pos != bytes.size()) throw Failure("incomplete PNG");
    if (!decode) return image;

    static const int passes[7][4] = {{0,0,8,8},{4,0,8,8},{0,4,4,8},{2,0,4,4},{0,2,2,4},{1,0,2,2},{0,1,1,2}};
    const int passCount = image.interlace ? 7 : 1;
    uint64_t expected = 0, canonicalBytes = 0, maximumRowBytes = 0;
    for (int pass = 0; pass < passCount; ++pass) {
        const int x0 = image.interlace ? passes[pass][0] : 0, y0 = image.interlace ? passes[pass][1] : 0;
        const int dx = image.interlace ? passes[pass][2] : 1, dy = image.interlace ? passes[pass][3] : 1;
        const uint64_t pw = image.width > uint32_t(x0) ? (image.width - x0 + dx - 1) / dx : 0;
        const uint64_t ph = image.height > uint32_t(y0) ? (image.height - y0 + dy - 1) / dy : 0;
        if (!pw || !ph) continue;
        const uint64_t rowBytes = (pw * pngChannels(image.colorType) * image.bitDepth + 7) / 8;
        if (rowBytes > kMaximumDecodedBytes || ph > kMaximumDecodedBytes / (rowBytes + 1) ||
            expected > kMaximumDecodedBytes - ph * (rowBytes + 1)) throw Failure("PNG decoded data exceeds the safety limit");
        expected += ph * (rowBytes + 1);
        canonicalBytes += ph * rowBytes;
        maximumRowBytes = std::max(maximumRowBytes, rowBytes);
    }
    uint64_t compressedBytes = 0;
    for (const auto &chunk : image.chunks) if (chunk.name() == "IDAT") compressedBytes += chunk.data.size();
    const uint64_t chunkOverhead = uint64_t(image.chunks.size()) * sizeof(PngChunk);
    if (canonicalBytes > kMaximumDecodedBytes || retainedBase + bytes.size() + storedChunkBytes + chunkOverhead > kMaximumWorkingBytes ||
        compressedBytes > kMaximumWorkingBytes - retainedBase - bytes.size() - storedChunkBytes - chunkOverhead ||
        expected > kMaximumWorkingBytes - retainedBase - bytes.size() - storedChunkBytes - chunkOverhead - compressedBytes ||
        canonicalBytes > kMaximumWorkingBytes - retainedBase - bytes.size() - storedChunkBytes - chunkOverhead - compressedBytes - expected ||
        maximumRowBytes * 2 > kMaximumWorkingBytes - retainedBase - bytes.size() - storedChunkBytes - chunkOverhead - compressedBytes - expected - canonicalBytes)
        throw Failure("PNG exceeds the cumulative memory safety limit");
    std::vector<uint8_t> compressed;
    compressed.reserve(size_t(compressedBytes));
    for (const auto &chunk : image.chunks) if (chunk.name() == "IDAT") compressed.insert(compressed.end(), chunk.data.begin(), chunk.data.end());
    std::vector<uint8_t> filtered((size_t(expected)));
    image.samples.reserve(size_t(canonicalBytes));
    z_stream stream{};
    stream.next_in = compressed.data(); stream.avail_in = uInt(compressed.size());
    stream.next_out = filtered.data(); stream.avail_out = uInt(filtered.size());
    if (inflateInit(&stream) != Z_OK) throw Failure("PNG decompressor unavailable");
    const int zstatus = inflate(&stream, Z_FINISH);
    const bool exactStream = zstatus == Z_STREAM_END && stream.total_in == compressed.size() && stream.total_out == expected;
    inflateEnd(&stream);
    if (!exactStream) throw Failure("invalid PNG compressed data");

    size_t offset = 0;
    const int channelCount = pngChannels(image.colorType);
    for (int pass = 0; pass < passCount; ++pass) {
        const int x0 = image.interlace ? passes[pass][0] : 0, y0 = image.interlace ? passes[pass][1] : 0;
        const int dx = image.interlace ? passes[pass][2] : 1, dy = image.interlace ? passes[pass][3] : 1;
        const size_t pw = image.width > uint32_t(x0) ? (image.width - x0 + dx - 1) / dx : 0;
        const size_t ph = image.height > uint32_t(y0) ? (image.height - y0 + dy - 1) / dy : 0;
        if (!pw || !ph) continue;
        const size_t rowBytes = (pw * channelCount * image.bitDepth + 7) / 8;
        const size_t bpp = std::max<size_t>(1, (channelCount * image.bitDepth + 7) / 8);
        std::vector<uint8_t> prior(rowBytes), row(rowBytes);
        for (size_t y = 0; y < ph; ++y) {
            if (offset + 1 + rowBytes > filtered.size()) throw Failure("truncated PNG scanline");
            const uint8_t filter = filtered[offset++];
            if (filter > 4) throw Failure("invalid PNG row filter");
            for (size_t x = 0; x < rowBytes; ++x) {
                const uint8_t raw = filtered[offset++];
                const uint8_t a = x >= bpp ? row[x - bpp] : 0;
                const uint8_t b = prior[x];
                const uint8_t c = x >= bpp ? prior[x - bpp] : 0;
                uint8_t value = raw;
                if (filter == 1) value = uint8_t(raw + a);
                else if (filter == 2) value = uint8_t(raw + b);
                else if (filter == 3) value = uint8_t(raw + ((int(a) + int(b)) >> 1));
                else if (filter == 4) {
                    const int p = int(a) + int(b) - int(c), pa = std::abs(p - int(a)), pb = std::abs(p - int(b)), pc = std::abs(p - int(c));
                    value = uint8_t(raw + (pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)));
                }
                row[x] = value;
            }
            if (image.bitDepth < 8 && rowBytes) {
                const size_t meaningfulBits = pw * channelCount * image.bitDepth;
                const unsigned remainder = unsigned(meaningfulBits & 7);
                if (remainder) row.back() &= uint8_t(0xff << (8 - remainder));
            }
            image.samples.insert(image.samples.end(), row.begin(), row.end());
            prior.swap(row);
        }
    }
    if (offset != filtered.size()) throw Failure("unexpected PNG decoded data");
    if (!keepIdat) {
        for (auto &chunk : image.chunks) if (chunk.name() == "IDAT") std::vector<uint8_t>().swap(chunk.data);
    }
    return image;
}

bool samePngNonIdat(const PngImage &a, const PngImage &b) {
    size_t ai = 0, bi = 0;
    while (true) {
        while (ai < a.chunks.size() && a.chunks[ai].name() == "IDAT") ++ai;
        while (bi < b.chunks.size() && b.chunks[bi].name() == "IDAT") ++bi;
        if (ai == a.chunks.size() || bi == b.chunks.size()) return ai == a.chunks.size() && bi == b.chunks.size();
        if (a.chunks[ai].type != b.chunks[bi].type || a.chunks[ai].data != b.chunks[bi].data) return false;
        ++ai; ++bi;
    }
}

struct JpegParsed {
    uint32_t width = 0, height = 0;
    int sof = -1, scans = 0;
    uint64_t metadataBytes = 0, coefficientBytes = 0;
    std::vector<std::pair<uint8_t, std::vector<uint8_t>>> metadata;
};

JpegParsed parseJpeg(const fs::path &path) {
    const auto bytes = readFile(path);
    if (bytes.size() < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) throw Failure("unsupported image format");
    JpegParsed result;
    size_t pos = 2;
    bool entropy = false, done = false;
    std::vector<uint8_t> app11Payloads;
    while (pos < bytes.size() && !done) {
        uint8_t marker = 0;
        if (entropy) {
            bool found = false;
            while (pos < bytes.size()) {
                if (bytes[pos++] != 0xff) continue;
                while (pos < bytes.size() && bytes[pos] == 0xff) ++pos;
                if (pos >= bytes.size()) throw Failure("truncated JPEG entropy stream");
                marker = bytes[pos++];
                if (marker == 0x00 || (marker >= 0xd0 && marker <= 0xd7)) continue;
                found = true; entropy = false; break;
            }
            if (!found) throw Failure("JPEG has no EOI marker");
        } else {
            if (bytes[pos++] != 0xff) throw Failure("malformed JPEG marker stream");
            while (pos < bytes.size() && bytes[pos] == 0xff) ++pos;
            if (pos >= bytes.size()) throw Failure("truncated JPEG marker");
            marker = bytes[pos++];
        }
        if (marker == 0xd9) {
            done = true;
            if (pos != bytes.size()) throw Failure("JPEG has trailing payload or a secondary codestream");
            break;
        }
        if (marker == 0xd8 || marker == 0x00 || (marker >= 0xd0 && marker <= 0xd7)) throw Failure("unexpected JPEG marker");
        if (marker == 0x01) continue;
        if (pos + 2 > bytes.size()) throw Failure("truncated JPEG segment");
        const uint16_t length = be16(bytes.data() + pos); pos += 2;
        if (length < 2 || pos + length - 2 > bytes.size()) throw Failure("invalid JPEG segment length");
        std::vector<uint8_t> payload(bytes.begin() + pos, bytes.begin() + pos + length - 2);
        pos += length - 2;
        if ((marker >= 0xe0 && marker <= 0xef) || marker == 0xfe) {
            if (payload.size() > kMaximumJpegMetadataBytes - result.metadataBytes)
                throw Failure("JPEG metadata exceeds the cumulative memory safety limit");
            result.metadataBytes += payload.size();
            result.metadata.emplace_back(marker, payload);
            if (marker == 0xeb) {
                if (payload.size() >= 2 && payload[0] == 'J' && payload[1] == 'P')
                    throw Failure("JPEG JUMBF or provenance metadata is unsupported");
                if (payload.size() > kMaximumApp11Bytes - app11Payloads.size())
                    throw Failure("JPEG APP11 metadata exceeds the safety limit");
                app11Payloads.insert(app11Payloads.end(), payload.begin(), payload.end());
            }
            if ((marker == 0xe2 && payload.size() >= 4 && std::memcmp(payload.data(), "MPF\0", 4) == 0) || containsUnsafeToken(payload))
                throw Failure("MPO, HDR, gain-map, signed, or provenance JPEG is unsupported");
        }
        if ((marker >= 0xc0 && marker <= 0xcf) && marker != 0xc4 && marker != 0xc8 && marker != 0xcc) {
            if (result.sof != -1 || payload.size() < 6) throw Failure("invalid JPEG frame header");
            result.sof = marker; result.height = be16(payload.data() + 1); result.width = be16(payload.data() + 3);
            if (marker != 0xc0 && marker != 0xc1 && marker != 0xc2) throw Failure("unsupported JPEG coding mode");
            if (!result.width || !result.height || payload[0] != 8) throw Failure("unsupported JPEG precision or dimensions");
            const int components = payload[5];
            if (components < 1 || components > 4 || payload.size() != size_t(6 + components * 3))
                throw Failure("invalid JPEG component layout");
            int maxH = 0, maxV = 0;
            for (int component = 0; component < components; ++component) {
                const uint8_t sampling = payload[7 + component * 3];
                const int h = sampling >> 4, v = sampling & 15;
                if (h < 1 || h > 4 || v < 1 || v > 4 || payload[8 + component * 3] >= NUM_QUANT_TBLS)
                    throw Failure("unsupported JPEG component layout");
                maxH = std::max(maxH, h); maxV = std::max(maxV, v);
            }
            uint64_t blocks = 0;
            for (int component = 0; component < components; ++component) {
                const uint8_t sampling = payload[7 + component * 3];
                const uint64_t h = sampling >> 4, v = sampling & 15;
                const uint64_t widthBlocks = (uint64_t(result.width) * h + uint64_t(maxH) * 8 - 1) / (uint64_t(maxH) * 8);
                const uint64_t heightBlocks = (uint64_t(result.height) * v + uint64_t(maxV) * 8 - 1) / (uint64_t(maxV) * 8);
                if (widthBlocks > std::numeric_limits<uint64_t>::max() / heightBlocks ||
                    blocks > std::numeric_limits<uint64_t>::max() - widthBlocks * heightBlocks)
                    throw Failure("JPEG coefficient layout exceeds the safety limit");
                blocks += widthBlocks * heightBlocks;
            }
            if (blocks > kMaximumJpegCoefficientBytes / (DCTSIZE2 * sizeof(JCOEF)))
                throw Failure("JPEG coefficients exceed the safety limit");
            result.coefficientBytes = blocks * DCTSIZE2 * sizeof(JCOEF);
        }
        if (marker == 0xda) {
            if (++result.scans > kMaximumJpegScans) throw Failure("JPEG scan count exceeds the safety limit");
            entropy = true;
        }
    }
    if (!done || result.sof == -1 || result.scans == 0) throw Failure("incomplete JPEG");
    if (containsUnsafeToken(app11Payloads)) throw Failure("fragmented JPEG provenance metadata is unsupported");
    return result;
}

struct JpegError { jpeg_error_mgr base; jmp_buf jump; char message[JMSG_LENGTH_MAX]{}; };

void jpegErrorExit(j_common_ptr info) {
    auto *error = reinterpret_cast<JpegError *>(info->err);
    (*info->err->format_message)(info, error->message);
    longjmp(error->jump, 1);
}

struct JpegComponentLayout { int id, h, v, quant, widthBlocks, heightBlocks; };
struct JpegCoefficients {
    uint32_t width = 0, height = 0;
    int precision = 0, colorSpace = 0;
    std::vector<JpegComponentLayout> layout;
    std::array<std::vector<uint16_t>, NUM_QUANT_TBLS> quant;
    std::vector<std::vector<JCOEF>> coefficients;
};

JpegCoefficients loadJpegCoefficients(const fs::path &path, uint64_t maximumCoefficientBytes) {
    FILE *file = std::fopen(path.c_str(), "rb");
    if (!file) throw Failure("JPEG file unavailable");
    jpeg_decompress_struct info{};
    JpegError error{};
    info.err = jpeg_std_error(&error.base);
    error.base.error_exit = jpegErrorExit;
    JpegCoefficients result;
    volatile bool created = false;
    if (setjmp(error.jump)) {
        if (created) jpeg_destroy_decompress(&info);
        std::fclose(file);
        throw Failure(std::string("invalid JPEG: ") + error.message);
    }
    jpeg_create_decompress(&info); created = true;
    info.mem->max_memory_to_use = long(256ULL * 1024 * 1024);
    jpeg_stdio_src(&info, file);
    jpeg_read_header(&info, TRUE);
    uint64_t headerCoefficientBytes = 0;
    for (int component = 0; component < info.num_components; ++component) {
        const auto &ci = info.comp_info[component];
        const uint64_t blocks = uint64_t(ci.width_in_blocks) * ci.height_in_blocks;
        if (blocks > kMaximumJpegCoefficientBytes / (DCTSIZE2 * sizeof(JCOEF)) ||
            headerCoefficientBytes > kMaximumJpegCoefficientBytes - blocks * DCTSIZE2 * sizeof(JCOEF)) {
            jpeg_destroy_decompress(&info); std::fclose(file); throw Failure("JPEG coefficients exceed the safety limit");
        }
        headerCoefficientBytes += blocks * DCTSIZE2 * sizeof(JCOEF);
    }
    if (headerCoefficientBytes > maximumCoefficientBytes) {
        jpeg_destroy_decompress(&info); std::fclose(file); throw Failure("JPEG exceeds the cumulative memory safety limit");
    }
    jvirt_barray_ptr *arrays = jpeg_read_coefficients(&info);
    result.width = info.image_width; result.height = info.image_height;
    result.precision = info.data_precision; result.colorSpace = int(info.jpeg_color_space);
    uint64_t coefficientBytes = 0;
    for (int table = 0; table < NUM_QUANT_TBLS; ++table) {
        if (!info.quant_tbl_ptrs[table]) continue;
        result.quant[table].assign(info.quant_tbl_ptrs[table]->quantval, info.quant_tbl_ptrs[table]->quantval + DCTSIZE2);
    }
    for (int component = 0; component < info.num_components; ++component) {
        const auto &ci = info.comp_info[component];
        result.layout.push_back({ci.component_id, ci.h_samp_factor, ci.v_samp_factor, ci.quant_tbl_no,
                                 int(ci.width_in_blocks), int(ci.height_in_blocks)});
        const uint64_t count = uint64_t(ci.width_in_blocks) * ci.height_in_blocks * DCTSIZE2;
        if (count > maximumCoefficientBytes / sizeof(JCOEF) || coefficientBytes > maximumCoefficientBytes - count * sizeof(JCOEF)) {
            jpeg_destroy_decompress(&info); std::fclose(file); throw Failure("JPEG coefficients exceed the safety limit");
        }
        coefficientBytes += count * sizeof(JCOEF);
        auto &values = result.coefficients.emplace_back();
        values.reserve(size_t(count));
        for (JDIMENSION row = 0; row < ci.height_in_blocks; ++row) {
            JBLOCKARRAY blocks = (*info.mem->access_virt_barray)(reinterpret_cast<j_common_ptr>(&info), arrays[component], row, 1, FALSE);
            for (JDIMENSION block = 0; block < ci.width_in_blocks; ++block)
                values.insert(values.end(), blocks[0][block], blocks[0][block] + DCTSIZE2);
        }
    }
    jpeg_abort_decompress(&info);
    jpeg_destroy_decompress(&info);
    std::fclose(file);
    return result;
}

bool sameJpegLayout(const JpegCoefficients &a, const JpegCoefficients &b) {
    if (a.width != b.width || a.height != b.height || a.precision != b.precision || a.colorSpace != b.colorSpace ||
        a.layout.size() != b.layout.size() || a.quant != b.quant || a.coefficients != b.coefficients) return false;
    for (size_t i = 0; i < a.layout.size(); ++i) {
        const auto &x = a.layout[i]; const auto &y = b.layout[i];
        if (x.id != y.id || x.h != y.h || x.v != y.v || x.quant != y.quant ||
            x.widthBlocks != y.widthBlocks || x.heightBlocks != y.heightBlocks) return false;
    }
    return true;
}

ImageResult inspect(const fs::path &path) {
    std::array<uint8_t, 8> prefix{};
    FILE *file = std::fopen(path.c_str(), "rb");
    if (!file) throw Failure("file unavailable");
    const size_t prefixSize = std::fread(prefix.data(), 1, prefix.size(), file);
    std::fclose(file);
    if (prefixSize >= 8 && prefix[0] == 0x89 && prefix[1] == 'P' && prefix[2] == 'N' && prefix[3] == 'G') {
        const auto png = parsePng(path);
        return {"png", png.width, png.height};
    }
    if (prefixSize >= 2 && prefix[0] == 0xff && prefix[1] == 0xd8) {
        const auto parsed = parseJpeg(path);
        if (parsed.coefficientBytes > kMaximumWorkingBytes / 2)
            throw Failure("JPEG exceeds the cumulative memory safety limit");
        const auto coefficients = loadJpegCoefficients(path, kMaximumWorkingBytes / 2);
        return {"jpeg", coefficients.width, coefficients.height};
    }
    throw Failure("unsupported image format");
}

ImageResult compare(const fs::path &original, const fs::path &candidate) {
    auto magic = [](const fs::path &path) {
        std::array<uint8_t, 8> bytes{};
        FILE *file = std::fopen(path.c_str(), "rb");
        if (!file) throw Failure("file unavailable");
        const size_t count = std::fread(bytes.data(), 1, bytes.size(), file); std::fclose(file);
        return std::make_pair(bytes, count);
    };
    const auto [aBytes, aSize] = magic(original); const auto [bBytes, bSize] = magic(candidate);
    const bool aPng = aSize >= 8 && aBytes[0] == 0x89 && aBytes[1] == 'P' && aBytes[2] == 'N' && aBytes[3] == 'G';
    const bool bPng = bSize >= 8 && bBytes[0] == 0x89 && bBytes[1] == 'P' && bBytes[2] == 'N' && bBytes[3] == 'G';
    const bool aJpeg = aSize >= 2 && aBytes[0] == 0xff && aBytes[1] == 0xd8;
    const bool bJpeg = bSize >= 2 && bBytes[0] == 0xff && bBytes[1] == 0xd8;
    if (aPng && bPng) {
        const auto a = parsePng(original, true, 0, false);
        const auto b = parsePng(candidate, true, a.retainedBytes(), false);
        if (!samePngNonIdat(a, b)) throw Failure("PNG non-IDAT chunks or metadata differ");
        if (a.samples != b.samples) throw Failure("PNG decoded samples differ");
        return {"png", a.width, a.height};
    }
    if (aJpeg && bJpeg) {
        const auto ap = parseJpeg(original), bp = parseJpeg(candidate);
        if (ap.metadataBytes > kMaximumWorkingBytes || bp.metadataBytes > kMaximumWorkingBytes - ap.metadataBytes)
            throw Failure("JPEG comparison exceeds the cumulative memory safety limit");
        const uint64_t metadataTotal = ap.metadataBytes + bp.metadataBytes;
        if (ap.coefficientBytes > (kMaximumWorkingBytes - metadataTotal) / 2 ||
            bp.coefficientBytes > (kMaximumWorkingBytes - metadataTotal - ap.coefficientBytes) / 2)
            throw Failure("JPEG comparison exceeds the cumulative memory safety limit");
        if (ap.metadata != bp.metadata) throw Failure("JPEG APP or COM metadata differ");
        const auto a = loadJpegCoefficients(original, kMaximumJpegCoefficientBytes);
        const uint64_t remainingForCandidate = (kMaximumWorkingBytes - metadataTotal - ap.coefficientBytes) / 2;
        const auto b = loadJpegCoefficients(candidate, std::min(kMaximumJpegCoefficientBytes, remainingForCandidate));
        if (!sameJpegLayout(a, b)) throw Failure("JPEG coefficients, quantization, or sample layout differ");
        return {"jpeg", a.width, a.height};
    }
    throw Failure("image container types differ or are unsupported");
}

bool samePath(const fs::path &a, const fs::path &b) {
    std::error_code ec;
    if (fs::exists(a, ec) && fs::exists(b, ec) && fs::equivalent(a, b, ec) && !ec) return true;
    return fs::absolute(a).lexically_normal() == fs::absolute(b).lexically_normal();
}

void writeExclusive(const fs::path &path, const std::vector<uint8_t> &bytes) {
    const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) throw Failure(errno == EEXIST ? "output already exists" : "cannot create output");
    size_t offset = 0;
    while (offset < bytes.size()) {
        const ssize_t wrote = ::write(fd, bytes.data() + offset, bytes.size() - offset);
        if (wrote <= 0) { const int saved = errno; ::close(fd); ::unlink(path.c_str()); errno = saved; throw Failure("output write failed"); }
        offset += size_t(wrote);
    }
    const bool syncFailed = ::fsync(fd) != 0;
    const bool closeFailed = ::close(fd) != 0;
    if (syncFailed || closeFailed) { ::unlink(path.c_str()); throw Failure("output finalization failed"); }
}

ImageResult restorePng(const fs::path &original, const fs::path &optimized, const fs::path &output) {
    if (samePath(original, optimized) || samePath(original, output) || samePath(optimized, output)) throw Failure("input and output paths must be distinct");
    if (fs::exists(output)) throw Failure("output already exists");
    const auto a = parsePng(original, true, 0, false);
    const auto b = parsePng(optimized, true, a.retainedBytes(), true);
    if (a.width != b.width || a.height != b.height || a.bitDepth != b.bitDepth || a.colorType != b.colorType ||
        a.interlace != b.interlace || a.samples != b.samples) throw Failure("optimized PNG samples or layout differ");
    std::vector<const PngChunk *> optimizedIdat;
    for (const auto &chunk : b.chunks) if (chunk.name() == "IDAT") optimizedIdat.push_back(&chunk);
    if (optimizedIdat.empty()) throw Failure("optimized PNG has no IDAT");
    uint64_t rebuiltSize = 8;
    for (const auto &chunk : a.chunks) if (chunk.name() != "IDAT") rebuiltSize += chunk.data.size() + 12;
    for (const auto *chunk : optimizedIdat) rebuiltSize += chunk->data.size() + 12;
    if (rebuiltSize > kMaximumFileBytes || a.retainedBytes() + b.retainedBytes() > kMaximumWorkingBytes ||
        rebuiltSize > kMaximumWorkingBytes - a.retainedBytes() - b.retainedBytes())
        throw Failure("PNG restore exceeds the cumulative memory safety limit");
    std::vector<uint8_t> rebuilt = {0x89,'P','N','G',0x0d,0x0a,0x1a,0x0a};
    rebuilt.reserve(size_t(rebuiltSize));
    bool inserted = false;
    for (const auto &chunk : a.chunks) {
        if (chunk.name() == "IDAT") {
            if (!inserted) {
                for (const auto *idat : optimizedIdat) {
                    appendPngChunk(rebuilt, *idat);
                }
                inserted = true;
            }
        } else {
            appendPngChunk(rebuilt, chunk);
        }
    }
    writeExclusive(output, rebuilt);
    try { return compare(original, output); }
    catch (...) { ::unlink(output.c_str()); throw; }
}

void printSuccess(const ImageResult &result) {
    std::cout << "{\"ok\":true,\"kind\":\"" << result.kind << "\",\"width\":" << result.width
              << ",\"height\":" << result.height << "}\n";
}

} // namespace

int main(int argc, char **argv) {
    try {
        if (argc < 2) throw Failure("usage: image-verify inspect|compare|restore-png ...");
        const std::string command = argv[1];
        ImageResult result;
        if (command == "inspect" && argc == 3) result = inspect(argv[2]);
        else if (command == "compare" && argc == 4) result = compare(argv[2], argv[3]);
        else if (command == "restore-png" && argc == 5) result = restorePng(argv[2], argv[3], argv[4]);
        else throw Failure("invalid arguments");
        printSuccess(result);
        return 0;
    } catch (const std::exception &error) {
        std::cout << "{\"ok\":false,\"reason\":\"" << jsonEscape(error.what()) << "\"}\n";
        return 2;
    }
}
