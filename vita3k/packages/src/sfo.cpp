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

/**
 * @file sfo.cpp
 * @brief PlayStation setting file (`.sfo`) handling
 *
 * PlayStation setting files (`.sfo`) contain metadata information usually describing
 * the content they are accompanying.
 */

#include <packages/sfo.h>

#include <boost/algorithm/string/trim.hpp>

#include <algorithm>
#include <cstring>
#include <fmt/format.h>
#include <limits>

namespace sfo {

bool get_data_by_id(std::string &out_data, SfoFile &file, int id) {
    std::string key;
    switch (id) {
    case 6:
        key = "CONTENT_ID";
        break;
    case 7:
        key = "NP_COMMUNICATION_ID";
        break;
    case 8:
        key = "CATEGORY";
        break;
    case 9:
        key = "TITLE";
        break;
    case 10:
        key = "STITLE";
        break;
    case 0xc:
        key = "TITLE_ID";
        break;
    case 0xe: // Todo
    default:
        return false;
    }

    return get_data_by_key(out_data, file, key);
}

bool get_data_by_key(std::string &out_data, SfoFile &file, const std::string &key) {
    auto res = std::ranges::find_if(file.entries,
        [key](const auto &et) { return et.data.first == key; });

    if (res == file.entries.end()) {
        return false;
    }
    out_data = res->data.second;

    return true;
}

bool get_param_info(sfo::SfoAppInfo &app_info, const vfs::FileBuffer &param, int sys_lang) {
    SfoFile sfo_handle;
    if (!sfo::load(sfo_handle, param)) {
        app_info = {};
        return false;
    }

    SfoAppInfo parsed_info;
    sfo::get_data_by_key(parsed_info.app_version, sfo_handle, "APP_VER");
    if (!parsed_info.app_version.empty() && parsed_info.app_version[0] == '0')
        parsed_info.app_version.erase(parsed_info.app_version.begin());
    sfo::get_data_by_key(parsed_info.app_category, sfo_handle, "CATEGORY");
    sfo::get_data_by_key(parsed_info.app_content_id, sfo_handle, "CONTENT_ID");
    if (!sfo::get_data_by_key(parsed_info.app_addcont, sfo_handle, "INSTALL_DIR_ADDCONT"))
        sfo::get_data_by_key(parsed_info.app_addcont, sfo_handle, "TITLE_ID");
    if (!sfo::get_data_by_key(parsed_info.app_savedata, sfo_handle, "INSTALL_DIR_SAVEDATA"))
        sfo::get_data_by_key(parsed_info.app_savedata, sfo_handle, "TITLE_ID");
    sfo::get_data_by_key(parsed_info.app_parental_level, sfo_handle, "PARENTAL_LEVEL");
    if (!sfo::get_data_by_key(parsed_info.app_short_title, sfo_handle, fmt::format("STITLE_{:0>2d}", sys_lang)))
        sfo::get_data_by_key(parsed_info.app_short_title, sfo_handle, "STITLE");
    if (!sfo::get_data_by_key(parsed_info.app_title, sfo_handle, fmt::format("TITLE_{:0>2d}", sys_lang)))
        sfo::get_data_by_key(parsed_info.app_title, sfo_handle, "TITLE");
    std::ranges::replace(parsed_info.app_title, '\n', ' ');
    boost::trim(parsed_info.app_title);
    sfo::get_data_by_key(parsed_info.app_title_id, sfo_handle, "TITLE_ID");
    app_info = std::move(parsed_info);
    return true;
}

// Read leniently: homebrew and ports (VPKs made with vita-mksfoex and similar tools) often have
// param.sfo files that the Vita reads fine but that break strict rules: strings marked null-terminated
// without the null, keys out of order, odd data formats, a data length running past the end. The
// install used to refuse those as "damaged". Only a file that isn't an SFO at all (bad magic, tables
// outside the file) fails now; a bad entry is skipped and every readable one is kept
bool load(SfoFile &sfile, const std::vector<uint8_t> &content) {
    constexpr uint32_t SFO_MAGIC = 0x46535000;
    sfile = {};
    if (content.size() < sizeof(SfoHeader))
        return false;

    SfoFile parsed{};
    std::memcpy(&parsed.header, content.data(), sizeof(SfoHeader));
    if (parsed.header.magic != SFO_MAGIC
        || parsed.header.tables_entries > (content.size() - sizeof(SfoHeader)) / sizeof(SfoIndexTableEntry))
        return false;

    const size_t index_table_end = sizeof(SfoHeader)
        + static_cast<size_t>(parsed.header.tables_entries) * sizeof(SfoIndexTableEntry);
    const size_t key_table_start = parsed.header.key_table_start;
    // a data table start past the end only means the file was cut short after the keys
    const size_t data_table_start = std::min<size_t>(parsed.header.data_table_start, content.size());
    if (key_table_start < index_table_end || key_table_start > content.size())
        return false;
    // keys end where the data starts (or at the end of the file if the header has them the other way)
    const size_t key_table_end = data_table_start > key_table_start ? data_table_start : content.size();

    const auto text_until_null = [&](size_t begin, size_t end) {
        const auto first = content.begin() + begin;
        const auto last = std::find(first, content.begin() + end, uint8_t{ 0 });
        return std::string(first, last);
    };

    for (uint32_t i = 0; i < parsed.header.tables_entries; i++) {
        SfoFile::SfoEntry item{};
        std::memcpy(&item.entry, content.data() + sizeof(SfoHeader) + static_cast<size_t>(i) * sizeof(SfoIndexTableEntry),
            sizeof(SfoIndexTableEntry));

        const size_t key_begin = key_table_start + item.entry.key_offset;
        if (key_begin >= key_table_end)
            continue;
        item.data.first = text_until_null(key_begin, key_table_end);
        if (item.data.first.empty())
            continue;

        const size_t data_begin = data_table_start + static_cast<size_t>(item.entry.data_offset);
        if (data_begin > content.size())
            continue;
        const size_t data_size = std::min<size_t>(item.entry.data_len, content.size() - data_begin);

        if (item.entry.data_fmt == SfoDataFormat::UINT32_T) {
            uint32_t value = 0;
            std::memcpy(&value, content.data() + data_begin, std::min<size_t>(data_size, sizeof(value)));
            item.data.second = std::to_string(value);
        } else {
            // strings (UTF-8, null-terminated or not, ASCII, and formats no tool should write): the text up to
            // the first null
            item.data.second = text_until_null(data_begin, data_begin + data_size);
        }
        parsed.entries.push_back(std::move(item));
    }

    sfile = std::move(parsed);
    return true;
}

} // namespace sfo
