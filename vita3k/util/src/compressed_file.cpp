// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

#include <util/compressed_file.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>

#if defined(__APPLE__)
#include <compression.h>
#define HCZ_CODEC 1 // LZFSE
#elif defined(HCZ_TEST_ZLIB)
#include <zlib.h>
#define HCZ_CODEC 2 // zlib: only for tests on other systems
#else
#define HCZ_CODEC 0
#endif

namespace fs = std::filesystem;

namespace compressed_file {

namespace {

constexpr char MAGIC[8] = { 'H', 'I', 'N', 'O', 'K', 'I', 'Z', 1 };
constexpr uint32_t CHUNK_SIZE = 64 * 1024;
constexpr uint64_t HEADER_SIZE = 48;
// Files smaller than this, or that shrink less than 1/20, stay as they are
constexpr uint64_t MIN_FILE_SIZE = 64 * 1024;
const char *const TEMP_SUFFIX = ".hinoki-tmp";

struct Header {
    char magic[8];
    uint64_t size;
    uint32_t chunk_size;
    uint32_t chunk_count;
    uint32_t codec;
    uint32_t flags;
    uint64_t index_offset;
    uint64_t reserved;
};
static_assert(sizeof(Header) == HEADER_SIZE);

bool read_header(FILE *f, Header &h) {
    if (std::fseek(f, 0, SEEK_SET) != 0 || std::fread(&h, sizeof(h), 1, f) != 1)
        return false;
    if (std::memcmp(h.magic, MAGIC, sizeof(MAGIC)) != 0)
        return false;
    if (h.chunk_size == 0 || h.chunk_size > 16 * 1024 * 1024 || h.index_offset < HEADER_SIZE)
        return false;
    const uint64_t chunks = (h.size + h.chunk_size - 1) / h.chunk_size;
    return chunks == h.chunk_count;
}

#if HCZ_CODEC == 1
std::vector<uint8_t> &scratch(bool encode) {
    thread_local std::vector<uint8_t> enc, dec;
    auto &buf = encode ? enc : dec;
    if (buf.empty()) {
        const auto algorithm = COMPRESSION_LZFSE;
        const size_t size = encode ? compression_encode_scratch_buffer_size(algorithm) : compression_decode_scratch_buffer_size(algorithm);
        buf.resize(std::max<size_t>(size, 1));
    }
    return buf;
}
#endif

// Bytes written to dst, 0 when it didn't fit in capacity (the chunk is then kept as it was)
size_t encode(const uint8_t *src, size_t size, uint8_t *dst, size_t capacity) {
#if HCZ_CODEC == 1
    return compression_encode_buffer(dst, capacity, src, size, scratch(true).data(), COMPRESSION_LZFSE);
#elif HCZ_CODEC == 2
    uLongf out = capacity;
    if (compress2(dst, &out, src, size, 6) != Z_OK)
        return 0;
    return out;
#else
    return 0;
#endif
}

bool decode(const uint8_t *src, size_t size, uint8_t *dst, size_t original) {
#if HCZ_CODEC == 1
    return compression_decode_buffer(dst, original, src, size, scratch(false).data(), COMPRESSION_LZFSE) == original;
#elif HCZ_CODEC == 2
    uLongf out = original;
    return uncompress(dst, &out, src, size) == Z_OK && out == original;
#else
    return false;
#endif
}

// An open compressed file: reads give the original bytes. The last few chunks read are kept unpacked
class Reader {
public:
    static std::unique_ptr<Reader> open(const fs::path &path) {
        FILE *f = std::fopen(path.string().c_str(), "rb");
        if (!f)
            return {};
        auto reader = std::unique_ptr<Reader>(new Reader(f));
        if (!read_header(f, reader->header) || reader->header.codec != HCZ_CODEC)
            return {};
        reader->index.resize(static_cast<size_t>(reader->header.chunk_count) + 1);
        if (std::fseek(f, static_cast<long>(reader->header.index_offset), SEEK_SET) != 0
            || std::fread(reader->index.data(), sizeof(uint64_t), reader->index.size(), f) != reader->index.size())
            return {};
        for (size_t i = 0; i + 1 < reader->index.size(); i++) {
            if (reader->index[i + 1] < reader->index[i])
                return {};
        }
        return reader;
    }

    ~Reader() {
        if (file)
            std::fclose(file);
    }

    uint64_t size() const {
        return header.size;
    }

    // -1 on a damaged file
    int64_t read(uint8_t *out, uint64_t length) {
        uint64_t done = 0;
        while (done < length && position < header.size) {
            const uint64_t chunk = position / header.chunk_size;
            const uint8_t *data = unpacked(chunk);
            if (!data)
                return done > 0 ? static_cast<int64_t>(done) : -1;
            const uint64_t in_chunk = position - chunk * header.chunk_size;
            const uint64_t available = chunk_length(chunk) - in_chunk;
            const uint64_t take = std::min(available, length - done);
            std::memcpy(out + done, data + in_chunk, take);
            done += take;
            position += take;
        }
        return static_cast<int64_t>(done);
    }

    // -1 when out of range
    int64_t seek(int64_t offset, int whence) {
        int64_t base = 0;
        if (whence == SEEK_CUR)
            base = static_cast<int64_t>(position);
        else if (whence == SEEK_END)
            base = static_cast<int64_t>(header.size);
        const int64_t target = base + offset;
        if (target < 0)
            return -1;
        position = static_cast<uint64_t>(target);
        return target;
    }

private:
    explicit Reader(FILE *f)
        : file(f) {}

    uint64_t chunk_length(uint64_t chunk) const {
        return std::min<uint64_t>(header.chunk_size, header.size - chunk * header.chunk_size);
    }

    const uint8_t *unpacked(uint64_t chunk) {
        for (auto &slot : cache) {
            if (slot.chunk == static_cast<int64_t>(chunk)) {
                slot.used = ++clock;
                return slot.data.data();
            }
        }
        auto &slot = *std::min_element(cache.begin(), cache.end(), [](const Slot &a, const Slot &b) { return a.used < b.used; });
        slot.chunk = -1;
        const uint64_t original = chunk_length(chunk);
        const uint64_t stored = index[chunk + 1] - index[chunk];
        slot.data.resize(header.chunk_size);
        if (std::fseek(file, static_cast<long>(index[chunk]), SEEK_SET) != 0)
            return nullptr;
        if (stored == original) {
            if (std::fread(slot.data.data(), 1, original, file) != original)
                return nullptr;
        } else {
            packed.resize(stored);
            if (std::fread(packed.data(), 1, stored, file) != stored || !decode(packed.data(), stored, slot.data.data(), original))
                return nullptr;
        }
        slot.chunk = static_cast<int64_t>(chunk);
        slot.used = ++clock;
        return slot.data.data();
    }

    struct Slot {
        int64_t chunk = -1;
        uint64_t used = 0;
        std::vector<uint8_t> data;
    };

    FILE *file = nullptr;
    Header header{};
    std::vector<uint64_t> index;
    std::array<Slot, 4> cache;
    uint64_t clock = 0;
    std::vector<uint8_t> packed;
    uint64_t position = 0;
};

#if defined(__APPLE__)
int cookie_read(void *cookie, char *buf, int size) {
    const int64_t n = static_cast<Reader *>(cookie)->read(reinterpret_cast<uint8_t *>(buf), static_cast<uint64_t>(std::max(size, 0)));
    return n < 0 ? -1 : static_cast<int>(n);
}
fpos_t cookie_seek(void *cookie, fpos_t offset, int whence) {
    return static_cast<Reader *>(cookie)->seek(offset, whence);
}
int cookie_close(void *cookie) {
    delete static_cast<Reader *>(cookie);
    return 0;
}
#elif defined(__linux__)
ssize_t cookie_read(void *cookie, char *buf, size_t size) {
    const int64_t n = static_cast<Reader *>(cookie)->read(reinterpret_cast<uint8_t *>(buf), size);
    return n < 0 ? -1 : static_cast<ssize_t>(n);
}
int cookie_seek(void *cookie, off64_t *offset, int whence) {
    const int64_t at = static_cast<Reader *>(cookie)->seek(*offset, whence);
    if (at < 0)
        return -1;
    *offset = at;
    return 0;
}
int cookie_close(void *cookie) {
    delete static_cast<Reader *>(cookie);
    return 0;
}
#endif

fs::recursive_directory_iterator walk(const fs::path &dir, std::error_code &ec) {
    return fs::recursive_directory_iterator(dir, fs::directory_options::skip_permission_denied, ec);
}

fs::path temp_path(const fs::path &path) {
    fs::path temp = path;
    temp += TEMP_SUFFIX;
    return temp;
}

struct FileCloser {
    void operator()(FILE *f) const {
        if (f)
            std::fclose(f);
    }
};
using File = std::unique_ptr<FILE, FileCloser>;

bool cancelled(const std::atomic<bool> *cancel) {
    return cancel && cancel->load(std::memory_order_relaxed);
}

// The temporary file holds the same bytes as the original
bool same_content(const fs::path &original, const fs::path &packed) {
    File plain(std::fopen(original.string().c_str(), "rb"));
    auto reader = Reader::open(packed);
    if (!plain || !reader)
        return false;
    std::vector<uint8_t> a(1024 * 1024), b(1024 * 1024);
    uint64_t total = 0;
    while (true) {
        const size_t n = std::fread(a.data(), 1, a.size(), plain.get());
        const int64_t m = reader->read(b.data(), n);
        if (m != static_cast<int64_t>(n) || std::memcmp(a.data(), b.data(), n) != 0)
            return false;
        total += n;
        if (n < a.size())
            break;
    }
    return total == reader->size();
}

} // namespace

bool supported() {
    return HCZ_CODEC != 0;
}

bool is_compressed(const fs::path &path, uint64_t *original_size) {
    File f(std::fopen(path.string().c_str(), "rb"));
    Header h{};
    if (!f || !read_header(f.get(), h))
        return false;
    if (original_size)
        *original_size = h.size;
    return true;
}

FILE *open_read(const fs::path &path) {
    auto reader = Reader::open(path);
    if (!reader)
        return nullptr;
#if defined(__APPLE__)
    FILE *f = funopen(reader.get(), cookie_read, nullptr, cookie_seek, cookie_close);
#elif defined(__linux__)
    cookie_io_functions_t functions{};
    functions.read = cookie_read;
    functions.seek = cookie_seek;
    functions.close = cookie_close;
    FILE *f = fopencookie(reader.get(), "rb", functions);
#else
    FILE *f = nullptr;
#endif
    if (f) {
        reader.release(); // the stream owns it now
        // stdio's default buffer (1 KiB on Apple platforms) would cut big reads into 1 KiB calls
        std::setvbuf(f, nullptr, _IOFBF, 128 * 1024);
    }
    return f;
}

bool read_all(const fs::path &path, std::vector<uint8_t> &data) {
    auto reader = Reader::open(path);
    if (!reader)
        return false;
    data.resize(reader->size());
    return reader->read(data.data(), data.size()) == static_cast<int64_t>(data.size());
}

Result compress(const fs::path &path, const std::function<void(uint64_t)> &progress, const std::atomic<bool> *cancel) {
    if (!supported())
        return Result::Failed;
    std::error_code ec;
    const uint64_t size = fs::file_size(path, ec);
    if (ec || size < MIN_FILE_SIZE || is_compressed(path))
        return Result::Skipped;

    const fs::path temp = temp_path(path);
    {
        File in(std::fopen(path.string().c_str(), "rb"));
        File out(std::fopen(temp.string().c_str(), "wb"));
        if (!in || !out)
            return Result::Failed;
        Header h{};
        std::memcpy(h.magic, MAGIC, sizeof(MAGIC));
        h.size = size;
        h.chunk_size = CHUNK_SIZE;
        h.chunk_count = static_cast<uint32_t>((size + CHUNK_SIZE - 1) / CHUNK_SIZE);
        h.codec = HCZ_CODEC;
        h.index_offset = HEADER_SIZE;
        std::vector<uint64_t> index(static_cast<size_t>(h.chunk_count) + 1);
        bool ok = std::fwrite(&h, sizeof(h), 1, out.get()) == 1
            && std::fwrite(index.data(), sizeof(uint64_t), index.size(), out.get()) == index.size();
        uint64_t offset = HEADER_SIZE + index.size() * sizeof(uint64_t);
        std::vector<uint8_t> plain(CHUNK_SIZE), packed(CHUNK_SIZE);
        for (uint32_t i = 0; ok && i < h.chunk_count; i++) {
            if (cancelled(cancel)) {
                ok = false;
                break;
            }
            const size_t length = static_cast<size_t>(std::min<uint64_t>(CHUNK_SIZE, size - static_cast<uint64_t>(i) * CHUNK_SIZE));
            if (std::fread(plain.data(), 1, length, in.get()) != length) {
                ok = false;
                break;
            }
            // kept as it was unless it got smaller (a stored length equal to the real one means "as it was")
            size_t stored = encode(plain.data(), length, packed.data(), length - 1);
            const uint8_t *data = packed.data();
            if (stored == 0 || stored >= length) {
                stored = length;
                data = plain.data();
            }
            index[i] = offset;
            ok = std::fwrite(data, 1, stored, out.get()) == stored;
            offset += stored;
            if (progress)
                progress(length);
        }
        index[h.chunk_count] = offset;
        ok = ok && std::fseek(out.get(), static_cast<long>(HEADER_SIZE), SEEK_SET) == 0
            && std::fwrite(index.data(), sizeof(uint64_t), index.size(), out.get()) == index.size()
            && std::fflush(out.get()) == 0;
        if (!ok) {
            out.reset();
            fs::remove(temp, ec);
            return cancelled(cancel) ? Result::Skipped : Result::Failed;
        }
        // Not worth a slower read: data that was compressed already (audio, videos, packed archives)
        if (offset > size - size / 20) {
            out.reset();
            fs::remove(temp, ec);
            return Result::Skipped;
        }
    }
    if (!same_content(path, temp)) {
        fs::remove(temp, ec);
        return Result::Failed;
    }
    fs::rename(temp, path, ec);
    if (ec) {
        fs::remove(temp, ec);
        return Result::Failed;
    }
    return Result::Done;
}

Result decompress(const fs::path &path, const std::function<void(uint64_t)> &progress, const std::atomic<bool> *cancel) {
    uint64_t size = 0;
    if (!is_compressed(path, &size))
        return Result::Skipped;
    auto reader = Reader::open(path);
    if (!reader)
        return Result::Failed;
    const fs::path temp = temp_path(path);
    std::error_code ec;
    {
        File out(std::fopen(temp.string().c_str(), "wb"));
        if (!out)
            return Result::Failed;
        std::vector<uint8_t> buf(1024 * 1024);
        uint64_t done = 0;
        bool ok = true;
        while (ok && done < size) {
            if (cancelled(cancel)) {
                ok = false;
                break;
            }
            const int64_t n = reader->read(buf.data(), std::min<uint64_t>(buf.size(), size - done));
            ok = n > 0 && std::fwrite(buf.data(), 1, static_cast<size_t>(n), out.get()) == static_cast<size_t>(n);
            if (ok) {
                done += static_cast<uint64_t>(n);
                if (progress)
                    progress(static_cast<uint64_t>(n));
            }
        }
        ok = ok && std::fflush(out.get()) == 0;
        if (!ok) {
            out.reset();
            fs::remove(temp, ec);
            return cancelled(cancel) ? Result::Skipped : Result::Failed;
        }
    }
    reader.reset();
    if (fs::file_size(temp, ec) != size || ec) {
        fs::remove(temp, ec);
        return Result::Failed;
    }
    fs::rename(temp, path, ec);
    if (ec) {
        fs::remove(temp, ec);
        return Result::Failed;
    }
    return Result::Done;
}

bool should_compress(const fs::path &relative_path) {
    std::string rel = relative_path.generic_string();
    std::transform(rel.begin(), rel.end(), rel.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    // Read by the emulator or its loaders directly, or tiny anyway
    for (const char *folder : { "sce_sys/", "sce_module/", "sce_pfs/", "sce_patch/" }) {
        if (rel.rfind(folder, 0) == 0)
            return false;
    }
    if (rel == "eboot.bin")
        return false;
    std::string extension = relative_path.extension().string();
    std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    // Executables, and videos (played from their file by the video decoder, and compressed already)
    static const char *const kept[] = { ".self", ".suprx", ".sprx", ".skprx", ".elf", ".bin_", ".mp4", ".m4v", ".pmf", ".mov", ".avi", ".mkv", ".webm", ".wmv", ".mpg", ".mpeg", ".264", ".h264" };
    for (const char *skip : kept) {
        if (extension == skip)
            return false;
    }
    return true;
}

GameReport convert_game(const fs::path &app_dir, bool compress_files, const std::function<void(uint64_t, uint64_t)> &progress,
    const std::atomic<bool> *cancel) {
    GameReport report;
    std::error_code ec;
    std::vector<std::pair<fs::path, uint64_t>> work;
    uint64_t total = 0;
    for (auto it = walk(app_dir, ec); !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
        if (!it->is_regular_file(ec))
            continue;
        const fs::path &path = it->path();
        // left by a run the app didn't finish: the original is still there
        if (path.filename().string().ends_with(TEMP_SUFFIX)) {
            fs::remove(path, ec);
            continue;
        }
        const uint64_t size = it->file_size(ec);
        report.bytes_before += size;
        const bool packed = is_compressed(path);
        // decompressing takes every packed file, whatever its name
        if (compress_files ? (!packed && should_compress(fs::relative(path, app_dir, ec)) && size >= MIN_FILE_SIZE) : packed) {
            work.emplace_back(path, size);
            total += size;
        }
    }
    // biggest first: the progress bar moves evenly and the end isn't one long file
    std::sort(work.begin(), work.end(), [](const auto &a, const auto &b) { return a.second > b.second; });

    std::atomic<size_t> next{ 0 };
    std::atomic<uint64_t> done{ 0 };
    std::mutex report_mutex;
    const auto worker = [&] {
        while (!cancelled(cancel)) {
            const size_t i = next.fetch_add(1);
            if (i >= work.size())
                break;
            const auto step = [&](uint64_t bytes) {
                const uint64_t now = done.fetch_add(bytes) + bytes;
                if (progress)
                    progress(now, total);
            };
            const Result result = compress_files ? compress(work[i].first, step, cancel) : decompress(work[i].first, step, cancel);
            std::lock_guard lock(report_mutex);
            if (result == Result::Done)
                report.files++;
            else if (result == Result::Failed)
                report.failed++;
            else
                report.skipped++;
        }
    };
    // a few files at once: LZFSE uses one core per file
    const unsigned threads = std::clamp(std::thread::hardware_concurrency(), 1u, 4u);
    std::vector<std::thread> pool;
    for (unsigned t = 1; t < threads; t++)
        pool.emplace_back(worker);
    worker();
    for (auto &t : pool)
        t.join();
    report.cancelled = cancelled(cancel);

    for (auto it = walk(app_dir, ec); !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
        if (it->is_regular_file(ec))
            report.bytes_after += it->file_size(ec);
    }
    if (progress)
        progress(total, total);
    return report;
}

GameState game_state(const fs::path &app_dir) {
    GameState state;
    std::error_code ec;
    for (auto it = walk(app_dir, ec); !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
        if (!it->is_regular_file(ec))
            continue;
        const uint64_t stored = it->file_size(ec);
        uint64_t original = stored;
        if (stored >= HEADER_SIZE && is_compressed(it->path(), &original))
            state.compressed_files++;
        state.stored_bytes += stored;
        state.original_bytes += original;
    }
    return state;
}

} // namespace compressed_file
