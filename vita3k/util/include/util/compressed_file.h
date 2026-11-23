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

#pragma once

// Hinoki's compressed game files. An installed game's large files are packed one by one, each under
// its own name, in 64 KiB chunks compressed separately (LZFSE): any part of a file can be read without
// unpacking the rest, so games play from them. The emulator's file layer opens such a file as a stream
// that unpacks what is read (open_read), and reports its real size (is_compressed).
//
// Layout (little-endian): 48-byte header, then chunk_count + 1 offsets (u64, from the start of the file;
// the last is the end of the data), then the chunks. A chunk whose stored length equals its real length
// is kept as it was (it didn't compress).

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <string>
#include <vector>

namespace compressed_file {

// Whether this build can read and write them (Apple platforms: the Compression library)
bool supported();

// The file is one of ours; original_size gets its real size
bool is_compressed(const std::filesystem::path &path, uint64_t *original_size = nullptr);

// The same, remembered per path: a game's files don't change while it runs, and games open and stat
// the same files many times (each check otherwise opens the file). Compressing or decompressing a file
// here forgets it
bool is_compressed_cached(const std::filesystem::path &path, uint64_t *original_size = nullptr);

// A read-only stream giving the original bytes (fread/fseeko/ftello work), or nullptr when the file
// is not compressed or can't be read. Close with fclose
FILE *open_read(const std::filesystem::path &path);

// The whole original content. false when the file is not compressed or is damaged
bool read_all(const std::filesystem::path &path, std::vector<uint8_t> &data);

enum class Result {
    Done,
    Skipped, // not worth it (small, already compressed data) or already in the wanted state
    Failed, // left as it was
};

// In place, through a temporary file next to it that replaces the original only once it was read back
// and matched. progress gets bytes of the original handled so far
Result compress(const std::filesystem::path &path, const std::function<void(uint64_t)> &progress = {}, const std::atomic<bool> *cancel = nullptr);
Result decompress(const std::filesystem::path &path, const std::function<void(uint64_t)> &progress = {}, const std::atomic<bool> *cancel = nullptr);

// A whole installed game (ux0:app/<title ID>). Files the emulator or iOS read without going through the
// file layer stay as they are: sce_sys, sce_module, eboot.bin, executables and videos.
struct GameReport {
    uint64_t files = 0; // changed
    uint64_t skipped = 0;
    uint64_t failed = 0;
    uint64_t bytes_before = 0; // all files of the game
    uint64_t bytes_after = 0;
    bool cancelled = false;
};
bool should_compress(const std::filesystem::path &relative_path);
GameReport convert_game(const std::filesystem::path &app_dir, bool compress, const std::function<void(uint64_t done, uint64_t total)> &progress = {},
    const std::atomic<bool> *cancel = nullptr);
// How much of a game is compressed: files and bytes on disk vs. their real size
struct GameState {
    uint64_t compressed_files = 0;
    uint64_t stored_bytes = 0;
    uint64_t original_bytes = 0;
};
GameState game_state(const std::filesystem::path &app_dir);

} // namespace compressed_file
