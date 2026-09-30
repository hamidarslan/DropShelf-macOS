#include <qpdf/Pipeline.hh>
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFCryptoProvider.hh>
#include <qpdf/QPDFExc.hh>
#include <qpdf/QPDFObjectHandle.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFWriter.hh>

#include <sys/stat.h>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace
{
constexpr std::uint64_t max_file_bytes = 1024ULL * 1024ULL * 1024ULL;
constexpr std::uint64_t max_stream_bytes = 512ULL * 1024ULL * 1024ULL;
constexpr std::uint64_t max_total_stream_bytes = 2ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr std::size_t max_objects = 500000;
constexpr std::size_t max_nodes = 5000000;
constexpr int max_depth = 512;
constexpr auto max_runtime = std::chrono::seconds(30);

struct Reject: public std::runtime_error
{
    explicit Reject(std::string reason) :
        std::runtime_error(reason),
        reason(std::move(reason))
    {
    }
    std::string reason;
};

class HashPipeline: public Pipeline
{
  public:
    explicit HashPipeline(std::uint64_t limit) :
        Pipeline("pdf-verify hash", nullptr),
        limit(limit),
        crypto(QPDFCryptoProvider::getImpl())
    {
        crypto->SHA2_init(256);
    }

    void write(unsigned char const* data, size_t length) override
    {
        if (length > limit - count) {
            throw Reject("resource-limit");
        }
        count += length;
        crypto->SHA2_update(data, length);
    }

    void finish() override
    {
        if (!finished) {
            crypto->SHA2_finalize();
            digest = crypto->SHA2_digest();
            finished = true;
        }
    }

    std::uint64_t count{0};
    std::string digest;

  private:
    std::uint64_t limit;
    std::shared_ptr<QPDFCryptoImpl> crypto;
    bool finished{false};
};

class BoundedDiscard: public Pipeline
{
  public:
    explicit BoundedDiscard(std::uint64_t limit) :
        Pipeline("pdf-verify validation", nullptr),
        limit(limit)
    {
    }

    void write(unsigned char const*, size_t length) override
    {
        if (length > limit - count) {
            throw Reject("resource-limit");
        }
        count += length;
    }

    void finish() override {}

  private:
    std::uint64_t limit;
    std::uint64_t count{0};
};

struct StreamFingerprint
{
    std::uint64_t size;
    std::string digest;

    bool operator==(StreamFingerprint const& other) const
    {
        return size == other.size && digest == other.digest;
    }
};

bool
is_generalized_filter(QPDFObjectHandle filter)
{
    if (filter.isNull()) {
        return true;
    }
    if (filter.isName()) {
        auto const name = filter.getName();
        return name == "/FlateDecode" || name == "/Fl" || name == "/ASCIIHexDecode" ||
            name == "/AHx" || name == "/ASCII85Decode" || name == "/A85" ||
            name == "/LZWDecode" || name == "/LZW";
    }
    if (filter.isArray()) {
        for (int i = 0; i < filter.getArrayNItems(); ++i) {
            if (!is_generalized_filter(filter.getArrayItem(i))) {
                return false;
            }
        }
        return true;
    }
    return false;
}

bool
is_storage_object(QPDFObjectHandle object)
{
    if (!object.isStream()) {
        return false;
    }
    auto dict = object.getDict();
    auto type = dict.getKey("/Type");
    return type.isNameAndEquals("/ObjStm") || type.isNameAndEquals("/XRef");
}

class Document
{
  public:
    explicit Document(std::string const& path) :
        deadline(std::chrono::steady_clock::now() + max_runtime)
    {
        struct stat info {};
        if (::stat(path.c_str(), &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0) {
            throw Reject("malformed");
        }
        if (static_cast<std::uint64_t>(info.st_size) > max_file_bytes) {
            throw Reject("resource-limit");
        }
        file_size = static_cast<std::uint64_t>(info.st_size);

        pdf.setSuppressWarnings(true);
        pdf.setAttemptRecovery(false);
        pdf.setMaxWarnings(1);
        try {
            pdf.processFile(path.c_str());
        } catch (QPDFExc const& error) {
            if (error.getErrorCode() == qpdf_e_password) {
                throw Reject("encrypted");
            }
            throw Reject("malformed");
        }
        if (pdf.isEncrypted()) {
            throw Reject("encrypted");
        }

        try {
            validate_trailer_id();
            auto all = pdf.getAllObjects();
            if (all.size() > max_objects) {
                throw Reject("resource-limit");
            }
            identify_storage_objects(all);
            scan_for_unsafe(pdf.getTrailer(), 0);
            for (auto object: all) {
                check_time();
                if (!is_storage(object)) {
                    objects.push_back(object);
                }
                scan_for_unsafe(object, 0);
                if (object.isStream() && !is_storage(object)) {
                    (void)stream_fingerprint(object);
                }
            }
            auto const& all_pages = pdf.getAllPages();
            if (all_pages.empty()) {
                throw Reject("malformed");
            }
            pages = static_cast<int>(all_pages.size());
            for (auto page: all_pages) {
                check_time();
                QPDFPageObjectHelper(page).parseContents(nullptr);
            }

            // Match qpdf --check's full traversal without writing any document to disk.
            BoundedDiscard discard(max_total_stream_bytes);
            QPDFWriter writer(pdf);
            writer.setOutputPipeline(&discard);
            writer.setDecodeLevel(qpdf_dl_all);
            writer.setCompressStreams(false);
            writer.write();
        } catch (Reject const&) {
            throw;
        } catch (...) {
            throw Reject("malformed");
        }
        if (pdf.anyWarnings()) {
            throw Reject("malformed");
        }
    }

    QPDF pdf;
    int pages{0};
    std::vector<QPDFObjectHandle> objects;

    bool verified_linearization_storage(std::set<QPDFObjGen>& result)
    {
        result.clear();
        if (pdf.anyWarnings()) {
            throw Reject("malformed");
        }
        if (!pdf.isLinearized()) {
            return false;
        }

        bool const valid = pdf.checkLinearization();
        auto const warnings = pdf.getWarnings();
        if (!valid || !warnings.empty()) {
            return false;
        }

        std::vector<QPDFObjectHandle> dictionaries;
        auto const& xref = pdf.getXRefTable();
        for (auto object: pdf.getAllObjects()) {
            if (!object.isIndirect() || !object.isDictionary() || !object.hasKey("/Linearized")) {
                continue;
            }
            auto linearized = object.getKey("/Linearized");
            auto length = object.getKey("/L");
            auto entry = xref.find(object.getObjGen());
            if (linearized.isNumber() && linearized.getNumericValue() >= 1.0 &&
                linearized.getNumericValue() < 2.0 && length.isInteger() &&
                length.getIntValue() == static_cast<long long>(file_size) &&
                entry != xref.end() && entry->second.getType() == 1 &&
                entry->second.getOffset() >= 0 && entry->second.getOffset() < 1024) {
                dictionaries.push_back(object);
            }
        }
        if (dictionaries.size() != 1) {
            return false;
        }

        auto dictionary = dictionaries.front();
        auto hints = dictionary.getKey("/H");
        if (!hints.isArray() || (hints.getArrayNItems() != 2 && hints.getArrayNItems() != 4)) {
            return false;
        }
        result.insert(dictionary.getObjGen());
        for (int i = 0; i < hints.getArrayNItems(); i += 2) {
            auto offset = hints.getArrayItem(i);
            auto length = hints.getArrayItem(i + 1);
            if (!offset.isInteger() || !length.isInteger() || offset.getIntValue() < 0 ||
                length.getIntValue() <= 0) {
                result.clear();
                return false;
            }
            bool found = false;
            for (auto const& [key, entry]: xref) {
                if (entry.getType() == 1 && entry.getOffset() == offset.getIntValue()) {
                    auto hint = pdf.getObject(key.getObj(), key.getGen());
                    if (!hint.isStream()) {
                        result.clear();
                        return false;
                    }
                    result.insert(key);
                    found = true;
                    break;
                }
            }
            if (!found) {
                result.clear();
                return false;
            }
        }
        return true;
    }

    StreamFingerprint stream_fingerprint(QPDFObjectHandle stream)
    {
        auto const key = stream.getObjGen();
        auto const found = streams.find(key);
        if (found != streams.end()) {
            return found->second;
        }
        check_time();
        bool const decoded = is_generalized_filter(stream.getDict().getKey("/Filter"));
        HashPipeline sink(max_stream_bytes);
        bool attempted = false;
        bool const okay = stream.pipeStreamData(
            &sink,
            &attempted,
            0,
            decoded ? qpdf_dl_generalized : qpdf_dl_none,
            false,
            false);
        if (!okay) {
            throw Reject("malformed");
        }
        sink.finish();
        if (sink.count > max_total_stream_bytes - total_stream_bytes) {
            throw Reject("resource-limit");
        }
        total_stream_bytes += sink.count;
        StreamFingerprint value{sink.count, sink.digest};
        streams[key] = value;
        return value;
    }

    bool stream_is_generalized(QPDFObjectHandle stream) const
    {
        return is_generalized_filter(stream.getDict().getKey("/Filter"));
    }

    void check_time() const
    {
        if (std::chrono::steady_clock::now() > deadline) {
            throw Reject("resource-limit");
        }
    }

  private:
    std::chrono::steady_clock::time_point deadline;
    std::uint64_t file_size{0};
    std::uint64_t total_stream_bytes{0};
    std::map<QPDFObjGen, StreamFingerprint> streams;
    std::set<QPDFObjGen> storage_objects;
    std::set<QPDFObjGen> scanned;
    std::size_t scan_nodes{0};

    void validate_trailer_id()
    {
        auto id = pdf.getTrailer().getKey("/ID");
        if (id.isNull()) {
            return;
        }
        if (id.isIndirect() || !id.isArray() || id.getArrayNItems() != 2) {
            throw Reject("malformed");
        }
        for (int i = 0; i < 2; ++i) {
            auto value = id.getArrayItem(i);
            if (value.isIndirect() || !value.isString()) {
                throw Reject("malformed");
            }
        }
    }

    bool is_storage(QPDFObjectHandle object) const
    {
        return is_storage_object(object) ||
            (object.isIndirect() && storage_objects.count(object.getObjGen()) != 0);
    }

    void identify_storage_objects(std::vector<QPDFObjectHandle> const& all)
    {
        for (auto object: all) {
            if (is_storage_object(object)) {
                storage_objects.insert(object.getObjGen());
            }
        }
    }

    void scan_for_unsafe(QPDFObjectHandle object, int depth)
    {
        check_time();
        if (++scan_nodes > max_nodes || depth > max_depth) {
            throw Reject("resource-limit");
        }
        if (object.isIndirect()) {
            auto const key = object.getObjGen();
            if (!scanned.insert(key).second) {
                return;
            }
        }
        if (object.isStream()) {
            auto dict = object.getDict();
            if (dict.hasKey("/F") || dict.hasKey("/FFilter") || dict.hasKey("/FDecodeParms")) {
                throw Reject("unsupported-stream");
            }
            scan_for_unsafe(dict, depth + 1);
            return;
        }
        if (object.isDictionary()) {
            auto keys = object.getKeys();
            if (keys.count("/ByteRange") != 0) {
                throw Reject("signed");
            }
            if (keys.count("/XFA") != 0) {
                throw Reject("xfa");
            }
            auto type = object.getKey("/Type");
            auto field_type = object.getKey("/FT");
            auto relationship = object.getKey("/AFRelationship");
            auto subtype = object.getKey("/Subtype");
            if (relationship.isNameAndEquals("/C2PA_Manifest") ||
                subtype.isNameAndEquals("/application/c2pa")) {
                throw Reject("provenance");
            }
            if (type.isNameAndEquals("/Sig") || type.isNameAndEquals("/DocTimeStamp") ||
                field_type.isNameAndEquals("/Sig")) {
                throw Reject("signed");
            }
            for (auto const& key: keys) {
                scan_for_unsafe(object.getKey(key), depth + 1);
            }
        } else if (object.isArray()) {
            int const count = object.getArrayNItems();
            if (count < 0 || static_cast<std::size_t>(count) > max_nodes - scan_nodes) {
                throw Reject("resource-limit");
            }
            for (int i = 0; i < count; ++i) {
                scan_for_unsafe(object.getArrayItem(i), depth + 1);
            }
        }
    }
};

class Comparator
{
  public:
    Comparator(Document& original, Document& candidate) :
        original(original),
        candidate(candidate),
        deadline(std::chrono::steady_clock::now() + max_runtime)
    {
    }

    bool compare()
    {
        if (original.pages != candidate.pages) {
            return false;
        }
        if (compare_views(original.objects, candidate.objects)) {
            return true;
        }

        std::set<QPDFObjGen> original_storage;
        std::set<QPDFObjGen> candidate_storage;
        bool const original_linearized =
            original.verified_linearization_storage(original_storage);
        bool const candidate_linearized =
            candidate.verified_linearization_storage(candidate_storage);
        if (!original_linearized && !candidate_linearized) {
            return false;
        }

        std::vector<QPDFObjectHandle> original_content;
        std::vector<QPDFObjectHandle> candidate_content;
        for (auto object: original.objects) {
            if (original_storage.count(object.getObjGen()) == 0) {
                original_content.push_back(object);
            }
        }
        for (auto object: candidate.objects) {
            if (candidate_storage.count(object.getObjGen()) == 0) {
                candidate_content.push_back(object);
            }
        }
        return compare_views(original_content, candidate_content);
    }

  private:
    Document& original;
    Document& candidate;
    std::chrono::steady_clock::time_point deadline;
    std::map<QPDFObjGen, QPDFObjGen> forward;
    std::map<QPDFObjGen, QPDFObjGen> reverse;
    std::size_t compared_nodes{0};

    bool compare_views(
        std::vector<QPDFObjectHandle> const& left_objects,
        std::vector<QPDFObjectHandle> const& right_objects)
    {
        if (left_objects.size() != right_objects.size()) {
            return false;
        }
        forward.clear();
        reverse.clear();
        if (!compare_object(original.pdf.getTrailer(), candidate.pdf.getTrailer(), 0, true)) {
            return false;
        }

        for (auto left: left_objects) {
            auto const left_key = left.getObjGen();
            if (forward.count(left_key) != 0) {
                continue;
            }
            bool matched = false;
            for (auto right: right_objects) {
                auto const right_key = right.getObjGen();
                if (reverse.count(right_key) != 0) {
                    continue;
                }
                auto const saved_forward = forward;
                auto const saved_reverse = reverse;
                if (compare_object(left, right, 0, false)) {
                    matched = true;
                    break;
                }
                forward = saved_forward;
                reverse = saved_reverse;
            }
            if (!matched) {
                return false;
            }
        }
        return forward.size() == left_objects.size() && reverse.size() == right_objects.size();
    }

    void check_limits(int depth)
    {
        if (++compared_nodes > max_nodes || depth > max_depth ||
            std::chrono::steady_clock::now() > deadline) {
            throw Reject("resource-limit");
        }
    }

    bool compare_object(QPDFObjectHandle left, QPDFObjectHandle right, int depth, bool trailer)
    {
        check_limits(depth);
        bool const left_indirect = left.isIndirect();
        bool const right_indirect = right.isIndirect();
        if (left_indirect != right_indirect) {
            return false;
        }
        if (left_indirect) {
            auto const left_key = left.getObjGen();
            auto const right_key = right.getObjGen();
            auto const mapped = forward.find(left_key);
            if (mapped != forward.end()) {
                return mapped->second == right_key;
            }
            if (reverse.count(right_key) != 0) {
                return false;
            }
            forward[left_key] = right_key;
            reverse[right_key] = left_key;
        }

        if (left.getTypeCode() != right.getTypeCode()) {
            return false;
        }
        if (left.isStream()) {
            bool const left_generalized = original.stream_is_generalized(left);
            bool const right_generalized = candidate.stream_is_generalized(right);
            if (left_generalized != right_generalized) {
                // Unfiltered and generalized-filter streams are both logical byte streams.
                auto left_filter = left.getDict().getKey("/Filter");
                auto right_filter = right.getDict().getKey("/Filter");
                if (!(is_generalized_filter(left_filter) && is_generalized_filter(right_filter))) {
                    return false;
                }
            }
            if (!compare_dictionary(
                    left.getDict(),
                    right.getDict(),
                    depth + 1,
                    false,
                    left_generalized && right_generalized)) {
                return false;
            }
            return original.stream_fingerprint(left) == candidate.stream_fingerprint(right);
        }
        if (left.isDictionary()) {
            return compare_dictionary(left, right, depth + 1, trailer, false);
        }
        if (left.isArray()) {
            int const count = left.getArrayNItems();
            if (count != right.getArrayNItems()) {
                return false;
            }
            for (int i = 0; i < count; ++i) {
                if (!compare_object(left.getArrayItem(i), right.getArrayItem(i), depth + 1, false)) {
                    return false;
                }
            }
            return true;
        }
        return left.unparseResolved() == right.unparseResolved();
    }

    bool compare_dictionary(
        QPDFObjectHandle left,
        QPDFObjectHandle right,
        int depth,
        bool trailer,
        bool generalized_stream)
    {
        if (trailer && !compare_trailer_id(left, right)) {
            return false;
        }
        auto left_keys = left.getKeys();
        auto right_keys = right.getKeys();
        std::set<std::string> ignored;
        if (trailer) {
            ignored = {"/ID", "/Index", "/Length", "/Prev", "/Size", "/Type", "/W", "/XRefStm", "/Filter", "/DecodeParms"};
        } else if (generalized_stream) {
            ignored = {"/Length", "/Filter", "/DecodeParms"};
        } else {
            ignored = {"/Length"};
        }
        for (auto const& key: ignored) {
            left_keys.erase(key);
            right_keys.erase(key);
        }
        if (left_keys != right_keys) {
            return false;
        }
        for (auto const& key: left_keys) {
            if (!compare_object(left.getKey(key), right.getKey(key), depth + 1, false)) {
                return false;
            }
        }
        return true;
    }

    bool compare_trailer_id(QPDFObjectHandle left, QPDFObjectHandle right)
    {
        auto left_id = left.getKey("/ID");
        auto right_id = right.getKey("/ID");
        if (left_id.isNull()) {
            // A writer may add a trailer ID to a document that did not have one.
            return true;
        }
        if (right_id.isNull()) {
            return false;
        }
        // Document validation proved both values are two-element arrays of direct strings.
        // The first is the permanent identifier. The second is the update-instance identifier.
        return left_id.getArrayItem(0).getStringValue() ==
            right_id.getArrayItem(0).getStringValue();
    }
};

void print_success(int pages, bool include_pages)
{
    std::cout << "{\"ok\":true,\"kind\":\"pdf\"";
    if (include_pages) {
        std::cout << ",\"pages\":" << pages;
    }
    std::cout << "}\n";
}

void print_reject(std::string const& reason)
{
    std::cout << "{\"ok\":false,\"reason\":\"" << reason << "\"}\n";
}
}

int main(int argc, char* argv[])
{
    try {
        if (argc == 3 && std::string(argv[1]) == "inspect") {
            Document input(argv[2]);
            print_success(input.pages, true);
            return 0;
        }
        if (argc == 4 && std::string(argv[1]) == "compare") {
            Document original(argv[2]);
            Document candidate(argv[3]);
            Comparator comparator(original, candidate);
            if (!comparator.compare()) {
                throw Reject("content-mismatch");
            }
            if (original.pdf.anyWarnings() || candidate.pdf.anyWarnings()) {
                throw Reject("malformed");
            }
            print_success(0, false);
            return 0;
        }
        print_reject("usage");
        return 2;
    } catch (Reject const& error) {
        print_reject(error.reason);
        return 2;
    } catch (...) {
        print_reject("malformed");
        return 2;
    }
}
