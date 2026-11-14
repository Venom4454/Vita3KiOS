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

#include <codec/at9_file.h>

extern "C" {
#include <libatrac9.h>
}

#include <algorithm>
#include <climits>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <vector>

namespace {
uint16_t rd16(const uint8_t *p) {
    return static_cast<uint16_t>(p[0] | (p[1] << 8));
}
uint32_t rd32(const uint8_t *p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) | (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}
void wr16(std::vector<uint8_t> &out, uint16_t v) {
    out.push_back(static_cast<uint8_t>(v));
    out.push_back(static_cast<uint8_t>(v >> 8));
}
void wr32(std::vector<uint8_t> &out, uint32_t v) {
    for (int i = 0; i < 4; i++)
        out.push_back(static_cast<uint8_t>(v >> (8 * i)));
}
} // namespace

static bool decode_at9_file_to_wav_impl(const std::string &input_path, const std::string &output_path) {
    std::ifstream in(input_path, std::ios::binary);
    if (!in)
        return false;
    const std::vector<uint8_t> file((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (file.size() < 12 || std::memcmp(file.data(), "RIFF", 4) != 0 || std::memcmp(file.data() + 8, "WAVE", 4) != 0)
        return false;

    const uint8_t *fmt = nullptr;
    size_t fmt_size = 0;
    const uint8_t *fact = nullptr;
    const uint8_t *data = nullptr;
    size_t data_size = 0;

    size_t pos = 12;
    while (pos + 8 <= file.size()) {
        const uint32_t size = rd32(&file[pos + 4]);
        const uint8_t *body = &file[pos + 8];
        const size_t available = std::min<size_t>(size, file.size() - (pos + 8));
        if (!std::memcmp(&file[pos], "fmt ", 4)) {
            fmt = body;
            fmt_size = available;
        } else if (!std::memcmp(&file[pos], "fact", 4) && available >= 12) {
            fact = body;
        } else if (!std::memcmp(&file[pos], "data", 4)) {
            data = body;
            data_size = available;
        }
        pos += 8 + size + (size & 1);
    }
    // fmt: format, channels, rate, bytes/s, block align, bits, cbSize, valid bits, mask, GUID(16), version, config
    if (!fmt || !data || fmt_size < 48)
        return false;

    const size_t block_align = rd16(fmt + 12);
    uint8_t config[4];
    std::memcpy(config, fmt + 44, 4);

    void *handle = Atrac9GetHandle();
    if (!handle)
        return false;
    if (Atrac9InitDecoder(handle, config) != 0) {
        Atrac9ReleaseHandle(handle);
        return false;
    }
    Atrac9CodecInfo info{};
    Atrac9GetCodecInfo(handle, &info);
    if (info.channels <= 0 || info.frameSamples <= 0 || info.framesInSuperframe <= 0 || block_align == 0) {
        Atrac9ReleaseHandle(handle);
        return false;
    }

    struct HandleGuard {
        void *handle;
        ~HandleGuard() { Atrac9ReleaseHandle(handle); }
    } guard{ handle };

    // fact: total samples per channel, input overlap, encoder delay
    size_t skip = 0, limit = SIZE_MAX;
    if (fact) {
        skip = rd32(fact + 8);
        limit = skip + static_cast<size_t>(rd32(fact));
    }

    // Streamed to disk one frame at a time: a long song decoded into one buffer needed ~100 MiB in one
    // piece, which failed (and crashed) when the app was short of address space. Written next to the
    // result and renamed at the end, so an interrupted decode never leaves a broken cached file
    const std::string part_path = output_path + ".part";
    std::ofstream out(part_path, std::ios::binary | std::ios::trunc);
    if (!out)
        return false;
    std::vector<uint8_t> header;
    const auto write_header = [&](uint32_t bytes) {
        header.clear();
        header.insert(header.end(), { 'R', 'I', 'F', 'F' });
        wr32(header, 36 + bytes);
        header.insert(header.end(), { 'W', 'A', 'V', 'E', 'f', 'm', 't', ' ' });
        wr32(header, 16);
        wr16(header, 1);
        wr16(header, static_cast<uint16_t>(info.channels));
        wr32(header, static_cast<uint32_t>(info.samplingRate));
        wr32(header, static_cast<uint32_t>(info.samplingRate * info.channels * 2));
        wr16(header, static_cast<uint16_t>(info.channels * 2));
        wr16(header, 16);
        header.insert(header.end(), { 'd', 'a', 't', 'a' });
        wr32(header, bytes);
        out.write(reinterpret_cast<const char *>(header.data()), static_cast<std::streamsize>(header.size()));
    };
    write_header(0); // sizes filled in at the end

    const size_t frame_shorts = static_cast<size_t>(info.frameSamples) * info.channels;
    std::vector<int16_t> frame(frame_shorts);
    size_t position = 0; // samples per channel decoded so far
    size_t written = 0; // samples per channel written
    for (size_t offset = 0; offset + block_align <= data_size && position < limit; offset += block_align) {
        const uint8_t *p = data + offset;
        for (int f = 0; f < info.framesInSuperframe && position < limit; f++) {
            int used = 0;
            if (Atrac9Decode(guard.handle, p, frame.data(), &used) != 0)
                break; // keep what was decoded: a damaged tail shouldn't cost the whole song
            p += used;
            const size_t frame_start = position;
            const size_t frame_end = position + static_cast<size_t>(info.frameSamples);
            position = frame_end;
            const size_t from = std::max(frame_start, skip), to = std::min(frame_end, limit);
            if (to <= from)
                continue;
            out.write(reinterpret_cast<const char *>(frame.data() + (from - frame_start) * info.channels),
                static_cast<std::streamsize>((to - from) * info.channels * 2));
            written += to - from;
        }
    }
    std::error_code ec;
    if (written == 0 || !out.good() || written * info.channels * 2 > UINT32_MAX - 64) {
        out.close();
        std::filesystem::remove(part_path, ec);
        return false;
    }
    out.seekp(0);
    write_header(static_cast<uint32_t>(written * info.channels * 2));
    out.close();
    if (out.fail()) {
        std::filesystem::remove(part_path, ec);
        return false;
    }
    std::filesystem::rename(part_path, output_path, ec);
    if (ec) {
        std::filesystem::remove(part_path, ec);
        return false;
    }
    return true;
}

bool decode_at9_file_to_wav(const std::string &input_path, const std::string &output_path) {
    // Menu music is optional: running out of memory here must never take the app down
    try {
        return decode_at9_file_to_wav_impl(input_path, output_path);
    } catch (...) {
        std::error_code ec;
        std::filesystem::remove(output_path + ".part", ec);
        return false;
    }
}
