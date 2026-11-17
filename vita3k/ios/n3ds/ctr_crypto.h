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

// 3DS content decryption with the player's own keys (aes_keys.txt dumped from their console with
// GodMode9, and seeddb.bin for games that use seeds). Encrypted .3ds/.cci/.cxi dumps and .cia files
// are decrypted into the form Azahar runs (NCCH "NoCrypto"), the way GodMode9's "decrypt" does.
// Formats: 3dbrew.org (NCSD, NCCH, CIA, Ticket, Title metadata, AES key scrambler).

#include <array>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <optional>
#include <string>

namespace n3ds {

using Key = std::array<uint8_t, 16>;

struct Keys {
    std::map<int, Key> key_x; // by keyslot: 0x2C, 0x25, 0x18, 0x1B, 0x3D
    std::map<int, Key> key_y;
    std::map<int, Key> normal;
    std::array<std::optional<Key>, 6> common_y; // ticket common keys (keyY of slot 0x3D)
    std::optional<Key> generator;

    // Reads aes_keys.txt (name=hex lines; Citra and Azahar names). Returns how many keys it found.
    int load(const std::filesystem::path &file);
    bool has_ncch() const { return key_x.count(0x2C) != 0; }
    bool has_ticket() const;
    std::string summary() const;
};

// seeddb.bin: seeds of games that use seed encryption, by title ID
using SeedDb = std::map<uint64_t, Key>;
SeedDb load_seeddb(const std::filesystem::path &file);

enum class FileKind { Unknown,
    NCSD,
    NCCH,
    CIA,
    ThreeDSX,
    ELF,
    Compressed };

struct Probe {
    FileKind kind = FileKind::Unknown;
    bool encrypted = false;
    uint64_t title_id = 0;
};

Probe probe(const std::filesystem::path &file);

using Progress = std::function<void(uint64_t done, uint64_t total)>;

// Decrypts a .3ds/.cci, .cxi or .cia in place (work on a copy). Returns an empty string on
// success, else what is missing or wrong, in plain words.
std::string decrypt_in_place(const std::filesystem::path &file, const Keys &keys, const SeedDb &seeds,
    const Progress &progress);

} // namespace n3ds
