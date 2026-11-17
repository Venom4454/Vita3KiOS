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

#include "ctr_crypto.h"

#include <openssl/evp.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <fstream>
#include <memory>
#include <vector>

namespace n3ds {

namespace fs = std::filesystem;

namespace {

constexpr uint32_t MAGIC_NCSD = 0x4453434E; // "NCSD"
constexpr uint32_t MAGIC_NCCH = 0x4843434E; // "NCCH"
constexpr uint32_t MAGIC_3DSX = 0x58534433; // "3DSX"
constexpr uint64_t CHUNK = 4 * 1024 * 1024;

// The AES engine's key scrambler constant (public, 3dbrew "AES Registers"); aes_keys.txt files
// usually carry it as "generator"
constexpr Key DEFAULT_GENERATOR{ 0x1F, 0xF9, 0xE9, 0xAA, 0xC5, 0xFE, 0x04, 0x08, 0x02, 0x45, 0x91, 0xDC, 0x5D, 0x52, 0x76, 0x8A };
// Fixed key of system titles marked "FixedCryptoKey" (3dbrew "NCCH")
constexpr Key SYSTEM_FIXED_KEY{ 0x52, 0x7C, 0xE6, 0x30, 0xA9, 0xCA, 0x30, 0x5F, 0x36, 0x96, 0xF3, 0xCD, 0xE9, 0x54, 0x19, 0x4B };

uint32_t le32(const uint8_t *p) {
    return p[0] | (p[1] << 8) | (p[2] << 16) | (static_cast<uint32_t>(p[3]) << 24);
}
uint64_t le64(const uint8_t *p) {
    return le32(p) | (static_cast<uint64_t>(le32(p + 4)) << 32);
}
uint16_t be16(const uint8_t *p) {
    return static_cast<uint16_t>((p[0] << 8) | p[1]);
}
uint32_t be32(const uint8_t *p) {
    return (static_cast<uint32_t>(p[0]) << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
}
uint64_t be64(const uint8_t *p) {
    return (static_cast<uint64_t>(be32(p)) << 32) | be32(p + 4);
}
uint64_t align_up(uint64_t value, uint64_t alignment) {
    return (value + alignment - 1) / alignment * alignment;
}

// ---- 128-bit big-endian arithmetic for the key scrambler ----
Key rol128(const Key &in, unsigned bits) {
    bits %= 128;
    Key out{};
    const unsigned bytes = bits / 8, rest = bits % 8;
    for (int i = 0; i < 16; i++) {
        const uint8_t hi = in[(i + bytes) % 16];
        const uint8_t lo = in[(i + bytes + 1) % 16];
        out[i] = static_cast<uint8_t>(rest ? (hi << rest) | (lo >> (8 - rest)) : hi);
    }
    return out;
}
Key add128(const Key &a, const Key &b) {
    Key out{};
    unsigned carry = 0;
    for (int i = 15; i >= 0; i--) {
        const unsigned sum = a[i] + b[i] + carry;
        out[i] = static_cast<uint8_t>(sum);
        carry = sum >> 8;
    }
    return out;
}
Key xor128(const Key &a, const Key &b) {
    Key out{};
    for (int i = 0; i < 16; i++)
        out[i] = a[i] ^ b[i];
    return out;
}
Key scramble(const Key &x, const Key &y, const Key &generator) {
    return rol128(add128(xor128(rol128(x, 2), y), generator), 87);
}
Key counter_plus(Key counter, uint64_t blocks) {
    for (int i = 15; i >= 0 && blocks; i--) {
        const uint64_t sum = counter[i] + (blocks & 0xFF);
        counter[i] = static_cast<uint8_t>(sum);
        blocks = (blocks >> 8) + (sum >> 8);
    }
    return counter;
}

bool parse_hex(const std::string &text, Key &out) {
    std::string hex;
    for (const char c : text) {
        if (std::isxdigit(static_cast<unsigned char>(c)))
            hex += c;
    }
    if (hex.size() != 32)
        return false;
    for (int i = 0; i < 16; i++)
        out[i] = static_cast<uint8_t>(std::stoul(hex.substr(i * 2, 2), nullptr, 16));
    return true;
}

std::array<uint8_t, 32> sha256(const void *data, size_t size) {
    std::array<uint8_t, 32> out{};
    unsigned int length = 0;
    EVP_Digest(data, size, out.data(), &length, EVP_sha256(), nullptr);
    return out;
}

struct CipherCtx {
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    ~CipherCtx() { EVP_CIPHER_CTX_free(ctx); }
};

// ---- In-place passes over a region of the file ----
class File {
public:
    explicit File(const fs::path &path)
        : stream(path, std::ios::in | std::ios::out | std::ios::binary) {}
    bool ok() const { return static_cast<bool>(stream); }
    bool read(uint64_t offset, void *data, size_t size) {
        stream.clear();
        stream.seekg(static_cast<std::streamoff>(offset));
        stream.read(static_cast<char *>(data), static_cast<std::streamsize>(size));
        return static_cast<size_t>(stream.gcount()) == size;
    }
    bool write(uint64_t offset, const void *data, size_t size) {
        stream.clear();
        stream.seekp(static_cast<std::streamoff>(offset));
        stream.write(static_cast<const char *>(data), static_cast<std::streamsize>(size));
        return static_cast<bool>(stream);
    }
    uint64_t size() {
        stream.clear();
        stream.seekg(0, std::ios::end);
        return static_cast<uint64_t>(stream.tellg());
    }

private:
    std::fstream stream;
};

struct Job {
    File &file;
    const Progress &progress;
    uint64_t done = 0;
    uint64_t total = 0;
    std::vector<uint8_t> buffer = std::vector<uint8_t>(CHUNK);

    void advance(uint64_t bytes) {
        done += bytes;
        if (progress)
            progress(std::min(done, total), total);
    }

    // AES-128-CTR over [offset, offset + size) with the counter at the start of the region
    bool ctr(uint64_t offset, uint64_t size, const Key &key, const Key &counter, bool count = true) {
        CipherCtx cipher;
        if (!cipher.ctx || EVP_DecryptInit_ex(cipher.ctx, EVP_aes_128_ctr(), nullptr, key.data(), counter.data()) != 1)
            return false;
        for (uint64_t at = 0; at < size;) {
            const size_t n = static_cast<size_t>(std::min<uint64_t>(CHUNK, size - at));
            if (!file.read(offset + at, buffer.data(), n))
                return false;
            int out = 0;
            if (EVP_DecryptUpdate(cipher.ctx, buffer.data(), &out, buffer.data(), static_cast<int>(n)) != 1)
                return false;
            if (!file.write(offset + at, buffer.data(), n))
                return false;
            at += n;
            if (count)
                advance(n);
        }
        return true;
    }

    // AES-128-CBC decryption over a region (sizes are multiples of 16)
    bool cbc(uint64_t offset, uint64_t size, const Key &key, const Key &iv) {
        CipherCtx cipher;
        if (!cipher.ctx || EVP_DecryptInit_ex(cipher.ctx, EVP_aes_128_cbc(), nullptr, key.data(), iv.data()) != 1)
            return false;
        EVP_CIPHER_CTX_set_padding(cipher.ctx, 0);
        for (uint64_t at = 0; at < size;) {
            const size_t n = static_cast<size_t>(std::min<uint64_t>(CHUNK, size - at));
            if (!file.read(offset + at, buffer.data(), n))
                return false;
            int out = 0;
            if (EVP_DecryptUpdate(cipher.ctx, buffer.data(), &out, buffer.data(), static_cast<int>(n)) != 1)
                return false;
            if (!file.write(offset + at, buffer.data(), n))
                return false;
            at += n;
            advance(n);
        }
        return true;
    }

    bool hash(uint64_t offset, uint64_t size, std::array<uint8_t, 32> &out) {
        std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)> md(EVP_MD_CTX_new(), &EVP_MD_CTX_free);
        if (!md || EVP_DigestInit_ex(md.get(), EVP_sha256(), nullptr) != 1)
            return false;
        for (uint64_t at = 0; at < size;) {
            const size_t n = static_cast<size_t>(std::min<uint64_t>(CHUNK, size - at));
            if (!file.read(offset + at, buffer.data(), n))
                return false;
            EVP_DigestUpdate(md.get(), buffer.data(), n);
            at += n;
        }
        unsigned int length = 0;
        return EVP_DigestFinal_ex(md.get(), out.data(), &length) == 1;
    }
};

bool ncch_encrypted(const uint8_t *header) {
    return le32(header + 0x100) == MAGIC_NCCH && (header[0x188 + 7] & 0x04) == 0;
}

// Decrypts the NCCH at base in place (exheader, ExeFS, RomFS) and marks it NoCrypto
std::string decrypt_ncch(Job &job, uint64_t base, const Keys &keys, const SeedDb &seeds) {
    std::array<uint8_t, 0x200> header{};
    if (!job.file.read(base, header.data(), header.size()) || le32(&header[0x100]) != MAGIC_NCCH)
        return "a game partition could not be read";
    uint8_t *flags = &header[0x188];
    if (flags[7] & 0x04)
        return {}; // already decrypted

    const uint64_t program_id = le64(&header[0x118]);
    const uint64_t unit = 0x200ull << flags[6];
    const Key &generator = keys.generator ? *keys.generator : DEFAULT_GENERATOR;

    Key key_y{};
    std::copy_n(header.begin(), 16, key_y.begin());
    Key primary{}, secondary{};
    if (flags[7] & 0x01) {
        // fixed key: zero for applications, the system fixed key for system titles
        primary = (program_id >> 32) & 0x10 ? SYSTEM_FIXED_KEY : Key{};
        secondary = primary;
    } else {
        const auto x2c = keys.key_x.find(0x2C);
        if (x2c == keys.key_x.end())
            return "your aes_keys.txt has no slot0x2CKeyX";
        primary = scramble(x2c->second, key_y, generator);

        int secondary_slot = 0x2C;
        switch (flags[3]) {
        case 0x00: secondary_slot = 0x2C; break;
        case 0x01: secondary_slot = 0x25; break;
        case 0x0A: secondary_slot = 0x18; break;
        case 0x0B: secondary_slot = 0x1B; break;
        default: return "this game uses an unknown kind of encryption";
        }
        const auto x2 = keys.key_x.find(secondary_slot);
        if (x2 == keys.key_x.end()) {
            char name[24];
            std::snprintf(name, sizeof(name), "slot0x%02XKeyX", secondary_slot);
            return std::string("your aes_keys.txt has no ") + name + " (this game needs it)";
        }
        Key secondary_y = key_y;
        if (flags[7] & 0x20) {
            const auto seed = seeds.find(program_id);
            if (seed == seeds.end())
                return "this game uses a seed that is not in your seeddb.bin (add a newer seeddb.bin)";
            // the seed must match the header's check value
            std::array<uint8_t, 24> check_input{};
            std::copy(seed->second.begin(), seed->second.end(), check_input.begin());
            for (int i = 0; i < 8; i++)
                check_input[16 + i] = static_cast<uint8_t>(program_id >> (8 * i));
            const auto check = sha256(check_input.data(), check_input.size());
            if (std::memcmp(check.data(), &header[0x114], 4) != 0)
                return "the seed in your seeddb.bin does not match this game";
            std::array<uint8_t, 32> y_input{};
            std::copy(key_y.begin(), key_y.end(), y_input.begin());
            std::copy(seed->second.begin(), seed->second.end(), y_input.begin() + 16);
            const auto digest = sha256(y_input.data(), y_input.size());
            std::copy_n(digest.begin(), 16, secondary_y.begin());
        }
        secondary = scramble(x2->second, secondary_y, generator);
    }

    // Counters (3dbrew "NCCH": version 0/2 use the partition ID and a section number, version 1
    // the section's offset)
    const uint16_t version = static_cast<uint16_t>(header[0x112] | (header[0x113] << 8));
    const uint32_t exheader_size = le32(&header[0x180]);
    const uint64_t exefs_offset = le32(&header[0x1A0]) * unit, exefs_size = le32(&header[0x1A4]) * unit;
    const uint64_t romfs_offset = le32(&header[0x1B0]) * unit, romfs_size = le32(&header[0x1B4]) * unit;
    Key exheader_ctr{}, exefs_ctr{}, romfs_ctr{};
    if (version == 1) {
        std::copy_n(&header[0x108], 8, exheader_ctr.begin());
        exefs_ctr = romfs_ctr = exheader_ctr;
        const auto put_be32 = [](Key &counter, uint32_t value) {
            counter[12] = static_cast<uint8_t>(value >> 24);
            counter[13] = static_cast<uint8_t>(value >> 16);
            counter[14] = static_cast<uint8_t>(value >> 8);
            counter[15] = static_cast<uint8_t>(value);
        };
        put_be32(exheader_ctr, 0x200);
        put_be32(exefs_ctr, static_cast<uint32_t>(exefs_offset));
        put_be32(romfs_ctr, static_cast<uint32_t>(romfs_offset));
    } else {
        std::reverse_copy(&header[0x108], &header[0x110], exheader_ctr.begin());
        exefs_ctr = romfs_ctr = exheader_ctr;
        exheader_ctr[8] = 1;
        exefs_ctr[8] = 2;
        romfs_ctr[8] = 3;
    }

    if (exheader_size && !job.ctr(base + 0x200, 0x800, primary, exheader_ctr))
        return "the extended header could not be decrypted";

    if (exefs_size) {
        // The ExeFS header (primary key) says where each file is: "icon" and "banner" use the
        // primary key, everything else (.code, logo) the secondary one (as GodMode9 and Azahar do)
        std::array<uint8_t, 0x200> exefs_header{};
        if (!job.file.read(base + exefs_offset, exefs_header.data(), exefs_header.size()))
            return "the ExeFS could not be read";
        {
            CipherCtx cipher;
            int out = 0;
            if (!cipher.ctx || EVP_DecryptInit_ex(cipher.ctx, EVP_aes_128_ctr(), nullptr, primary.data(), exefs_ctr.data()) != 1
                || EVP_DecryptUpdate(cipher.ctx, exefs_header.data(), &out, exefs_header.data(), static_cast<int>(exefs_header.size())) != 1)
                return "the ExeFS header could not be decrypted";
        }
        if (!job.file.write(base + exefs_offset, exefs_header.data(), exefs_header.size()))
            return "the ExeFS could not be written";
        job.advance(exefs_header.size());
        for (int i = 0; i < 10; i++) {
            const uint8_t *entry = &exefs_header[i * 16];
            const uint32_t offset = le32(entry + 8), size = le32(entry + 12);
            if (size == 0 || entry[0] == 0)
                continue;
            const bool primary_file = std::memcmp(entry, "icon", 4) == 0 || std::memcmp(entry, "banner", 6) == 0;
            const uint64_t at = 0x200ull + offset;
            if (at + size > exefs_size)
                return "the ExeFS is damaged";
            if (!job.ctr(base + exefs_offset + at, size, primary_file ? primary : secondary, counter_plus(exefs_ctr, at / 16)))
                return "the ExeFS could not be decrypted";
        }
    }

    if (romfs_size && !job.ctr(base + romfs_offset, romfs_size, secondary, romfs_ctr))
        return "the RomFS could not be decrypted";

    // NoCrypto from now on (as GodMode9 leaves a decrypted game)
    flags[3] = 0;
    flags[7] = static_cast<uint8_t>((flags[7] & ~(0x01 | 0x20)) | 0x04);
    if (!job.file.write(base + 0x188, flags, 8))
        return "the game header could not be written";
    return {};
}

uint64_t ncch_bytes(File &file, uint64_t base) {
    std::array<uint8_t, 0x200> header{};
    if (!file.read(base, header.data(), header.size()) || le32(&header[0x100]) != MAGIC_NCCH)
        return 0;
    const uint64_t unit = 0x200ull << header[0x188 + 6];
    return 0x800 + (le32(&header[0x1A4]) + le32(&header[0x1B4])) * unit;
}

size_t signature_size(uint32_t type) {
    switch (type) {
    case 0x10000: return 0x200 + 0x3C;
    case 0x10001: return 0x100 + 0x3C;
    case 0x10002: return 0x3C + 0x40;
    case 0x10003: return 0x200 + 0x3C;
    case 0x10004: return 0x100 + 0x3C;
    case 0x10005: return 0x3C + 0x40;
    default: return 0;
    }
}

std::string decrypt_cia(Job &job, const Keys &keys, const SeedDb &seeds) {
    std::array<uint8_t, 0x20> header{};
    if (!job.file.read(0, header.data(), header.size()))
        return "the CIA could not be read";
    const uint32_t header_size = le32(&header[0]);
    const uint32_t cert_size = le32(&header[0x08]), ticket_size = le32(&header[0x0C]), tmd_size = le32(&header[0x10]);
    const uint64_t content_size = le64(&header[0x18]);
    const uint64_t cert_offset = align_up(header_size, 64);
    const uint64_t ticket_offset = align_up(cert_offset + cert_size, 64);
    const uint64_t tmd_offset = align_up(ticket_offset + ticket_size, 64);
    const uint64_t content_offset = align_up(tmd_offset + tmd_size, 64);

    std::vector<uint8_t> ticket(ticket_size), tmd(tmd_size);
    if (!job.file.read(ticket_offset, ticket.data(), ticket.size()) || !job.file.read(tmd_offset, tmd.data(), tmd.size()))
        return "the CIA is damaged";
    const size_t ticket_sig = signature_size(be32(ticket.data()));
    const size_t tmd_sig = signature_size(be32(tmd.data()));
    if (!ticket_sig || !tmd_sig || 4 + ticket_sig + 0xB2 > ticket.size() || 4 + tmd_sig + 0xC4 + 0x900 > tmd.size())
        return "the CIA's ticket or title metadata is damaged";
    const uint8_t *ticket_data = &ticket[4 + ticket_sig];
    uint8_t *tmd_header = &tmd[4 + tmd_sig];
    const uint16_t content_count = be16(tmd_header + 0x9E);
    uint8_t *info_records = tmd_header + 0xC4;
    uint8_t *chunks = info_records + 0x900;
    if (chunks + content_count * 0x30ull > tmd.data() + tmd.size())
        return "the CIA's title metadata is damaged";

    // Title key, if any content is encrypted
    bool any_encrypted = false;
    for (uint16_t i = 0; i < content_count; i++)
        any_encrypted |= (be16(chunks + i * 0x30 + 6) & 0x1) != 0;
    Key title_key{};
    if (any_encrypted) {
        const uint8_t common_index = ticket_data[0xB1];
        const auto x3d = keys.key_x.find(0x3D);
        if (x3d == keys.key_x.end())
            return "your aes_keys.txt has no slot0x3DKeyX (needed for encrypted CIA files)";
        if (common_index >= keys.common_y.size() || !keys.common_y[common_index])
            return "your aes_keys.txt has no common" + std::to_string(common_index) + " key (needed for this CIA)";
        const Key common = scramble(x3d->second, *keys.common_y[common_index], keys.generator ? *keys.generator : DEFAULT_GENERATOR);
        Key iv{};
        std::copy_n(ticket_data + 0x9C, 8, iv.begin()); // title ID, big-endian
        std::copy_n(ticket_data + 0x7F, 16, title_key.begin());
        CipherCtx cipher;
        int out = 0;
        if (!cipher.ctx || EVP_DecryptInit_ex(cipher.ctx, EVP_aes_128_cbc(), nullptr, common.data(), iv.data()) != 1)
            return "the title key could not be decrypted";
        EVP_CIPHER_CTX_set_padding(cipher.ctx, 0);
        EVP_DecryptUpdate(cipher.ctx, title_key.data(), &out, title_key.data(), 16);
    }

    job.total = content_size * 2;
    uint64_t offset = content_offset;
    for (uint16_t i = 0; i < content_count; i++) {
        uint8_t *chunk = chunks + i * 0x30;
        const uint16_t index = be16(chunk + 4);
        const uint16_t type = be16(chunk + 6);
        const uint64_t size = be64(chunk + 8);
        if (offset + size > content_offset + content_size)
            break; // content not in this CIA
        if (type & 0x1) {
            Key iv{};
            iv[0] = static_cast<uint8_t>(index >> 8);
            iv[1] = static_cast<uint8_t>(index);
            if (!job.cbc(offset, size, title_key, iv))
                return "a CIA content could not be decrypted";
            chunk[7] &= static_cast<uint8_t>(~0x1);
        } else {
            job.advance(size);
        }
        std::array<uint8_t, 0x200> ncch{};
        if (job.file.read(offset, ncch.data(), ncch.size()) && ncch_encrypted(ncch.data())) {
            const std::string error = decrypt_ncch(job, offset, keys, seeds);
            if (!error.empty())
                return error;
        }
        std::array<uint8_t, 32> digest{};
        if (!job.hash(offset, size, digest))
            return "a CIA content could not be read back";
        std::copy(digest.begin(), digest.end(), chunk + 0x10);
        offset += size;
    }

    // Title metadata hashes over the changed content records (signatures stay as they are, as
    // GodMode9 leaves them; emulators don't check them)
    const auto chunk_hash = sha256(chunks, content_count * 0x30ull);
    std::copy(chunk_hash.begin(), chunk_hash.end(), info_records + 4);
    const auto info_hash = sha256(info_records, 0x900);
    std::copy(info_hash.begin(), info_hash.end(), tmd_header + 0xA4);
    if (!job.file.write(tmd_offset, tmd.data(), tmd.size()))
        return "the CIA could not be written";
    return {};
}

} // namespace

bool Keys::has_ticket() const {
    if (!key_x.count(0x3D))
        return false;
    return std::any_of(common_y.begin(), common_y.end(), [](const auto &key) { return key.has_value(); });
}

std::string Keys::summary() const {
    std::string text;
    for (const int slot : { 0x2C, 0x25, 0x18, 0x1B, 0x3D }) {
        char name[16];
        std::snprintf(name, sizeof(name), "0x%02X", slot);
        text += std::string(text.empty() ? "" : ", ") + name + (key_x.count(slot) ? " yes" : " no");
    }
    int commons = 0;
    for (const auto &key : common_y)
        commons += key ? 1 : 0;
    return text + ", common keys " + std::to_string(commons) + "/6";
}

int Keys::load(const fs::path &file) {
    std::ifstream in(file);
    if (!in)
        return 0;
    int count = 0;
    std::string line;
    while (std::getline(in, line)) {
        const auto equals = line.find('=');
        if (equals == std::string::npos || line.empty() || line[0] == '#' || line[0] == ':')
            continue;
        std::string name = line.substr(0, equals);
        name.erase(std::remove_if(name.begin(), name.end(), [](unsigned char c) { return std::isspace(c); }), name.end());
        Key key{};
        if (!parse_hex(line.substr(equals + 1), key))
            continue;
        std::string lower = name;
        std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return std::tolower(c); });
        if (lower == "generator" || lower == "generatorconstant") {
            generator = key;
            count++;
            continue;
        }
        unsigned index = 0;
        if (std::sscanf(lower.c_str(), "common%u", &index) == 1 && lower.size() <= 8) {
            if (index < common_y.size()) {
                common_y[index] = key;
                count++;
            }
            continue;
        }
        unsigned slot = 0;
        char kind = 0;
        if (std::sscanf(lower.c_str(), "slot0x%2xkey%c", &slot, &kind) == 2 && slot < 0x40) {
            if (kind == 'x')
                key_x[static_cast<int>(slot)] = key;
            else if (kind == 'y')
                key_y[static_cast<int>(slot)] = key;
            else if (kind == 'n')
                normal[static_cast<int>(slot)] = key;
            else
                continue;
            count++;
        }
    }
    return count;
}

SeedDb load_seeddb(const fs::path &file) {
    SeedDb seeds;
    std::ifstream in(file, std::ios::binary);
    if (!in)
        return seeds;
    std::array<uint8_t, 16> header{};
    if (!in.read(reinterpret_cast<char *>(header.data()), header.size()))
        return seeds;
    const uint32_t count = le32(header.data());
    for (uint32_t i = 0; i < count; i++) {
        std::array<uint8_t, 32> entry{};
        if (!in.read(reinterpret_cast<char *>(entry.data()), entry.size()))
            break;
        Key seed{};
        std::copy_n(&entry[8], 16, seed.begin());
        seeds[le64(entry.data())] = seed;
    }
    return seeds;
}

Probe probe(const fs::path &path) {
    Probe result;
    std::ifstream in(path, std::ios::binary);
    if (!in)
        return result;
    std::vector<uint8_t> head(0x4000);
    in.read(reinterpret_cast<char *>(head.data()), static_cast<std::streamsize>(head.size()));
    head.resize(static_cast<size_t>(in.gcount()));
    if (head.size() < 0x200)
        return result;

    // Compressed (Azahar's .zcci/.zcia/.z3dsx): the core reads them itself
    if (std::memcmp(head.data(), "Z3DS", 4) == 0) {
        result.kind = FileKind::Compressed;
        return result;
    }
    if (le32(head.data()) == MAGIC_3DSX) {
        result.kind = FileKind::ThreeDSX;
        return result;
    }
    if (head[0] == 0x7F && head[1] == 'E' && head[2] == 'L' && head[3] == 'F') {
        result.kind = FileKind::ELF;
        return result;
    }
    if (le32(&head[0x100]) == MAGIC_NCSD) {
        result.kind = FileKind::NCSD;
        const uint64_t partition0 = le32(&head[0x120]) * 0x200ull;
        std::array<uint8_t, 0x200> ncch{};
        in.clear();
        in.seekg(static_cast<std::streamoff>(partition0));
        if (in.read(reinterpret_cast<char *>(ncch.data()), ncch.size())) {
            result.encrypted = ncch_encrypted(ncch.data());
            result.title_id = le64(&ncch[0x118]);
        }
        return result;
    }
    if (le32(&head[0x100]) == MAGIC_NCCH) {
        result.kind = FileKind::NCCH;
        result.encrypted = ncch_encrypted(head.data());
        result.title_id = le64(&head[0x118]);
        return result;
    }
    // CIA: header size 0x2020, then sections at 64-byte boundaries
    if (le32(head.data()) == 0x2020) {
        result.kind = FileKind::CIA;
        const uint32_t cert_size = le32(&head[0x08]), ticket_size = le32(&head[0x0C]), tmd_size = le32(&head[0x10]);
        const uint64_t ticket_offset = align_up(align_up(0x2020, 64) + cert_size, 64);
        const uint64_t tmd_offset = align_up(ticket_offset + ticket_size, 64);
        const uint64_t content_offset = align_up(tmd_offset + tmd_size, 64);
        std::vector<uint8_t> tmd(tmd_size);
        in.clear();
        in.seekg(static_cast<std::streamoff>(tmd_offset));
        if (tmd_size && in.read(reinterpret_cast<char *>(tmd.data()), tmd.size())) {
            const size_t sig = signature_size(be32(tmd.data()));
            if (sig && 4 + sig + 0xC4 + 0x900 + 0x30 <= tmd.size()) {
                const uint8_t *tmd_header = &tmd[4 + sig];
                result.title_id = be64(tmd_header + 0x4C);
                const uint8_t *chunk = tmd_header + 0xC4 + 0x900;
                if (be16(chunk + 6) & 0x1) {
                    result.encrypted = true;
                } else {
                    std::array<uint8_t, 0x200> ncch{};
                    in.clear();
                    in.seekg(static_cast<std::streamoff>(content_offset));
                    if (in.read(reinterpret_cast<char *>(ncch.data()), ncch.size()))
                        result.encrypted = ncch_encrypted(ncch.data());
                }
            }
        }
    }
    return result;
}

std::string decrypt_in_place(const fs::path &path, const Keys &keys, const SeedDb &seeds, const Progress &progress) {
    const Probe info = probe(path);
    if (!info.encrypted)
        return {};
    File file(path);
    if (!file.ok())
        return "the file could not be opened";
    Job job{ file, progress };

    switch (info.kind) {
    case FileKind::NCCH:
        job.total = ncch_bytes(file, 0);
        return decrypt_ncch(job, 0, keys, seeds);
    case FileKind::NCSD: {
        std::array<uint8_t, 0x200> header{};
        if (!file.read(0, header.data(), header.size()))
            return "the game could not be read";
        for (int i = 0; i < 8; i++)
            job.total += ncch_bytes(file, le32(&header[0x120 + i * 8]) * 0x200ull);
        for (int i = 0; i < 8; i++) {
            const uint64_t offset = le32(&header[0x120 + i * 8]) * 0x200ull;
            const uint64_t size = le32(&header[0x124 + i * 8]) * 0x200ull;
            if (!size)
                continue;
            std::array<uint8_t, 0x200> ncch{};
            if (!file.read(offset, ncch.data(), ncch.size()) || !ncch_encrypted(ncch.data()))
                continue;
            const std::string error = decrypt_ncch(job, offset, keys, seeds);
            if (!error.empty()) {
                // the manual and download play partitions are optional: the game itself is not
                if (i == 0)
                    return error;
            }
        }
        return {};
    }
    case FileKind::CIA:
        return decrypt_cia(job, keys, seeds);
    default:
        return "this file can't be decrypted";
    }
}

} // namespace n3ds
