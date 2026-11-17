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

#include "n3ds.h"

#include "../ios_platform.h"
#include "azahar/hinoki/hinoki_azahar.h"
#include "ctr_crypto.h"

#include <cpu/functions.h>
#include <util/log.h>

#include <fmt/format.h>
#include <stb_image_write.h>

#include <dlfcn.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <mutex>
#include <type_traits>
#include <vector>

// The MoltenVK linked into the app (one Vulkan driver for both cores); only its address is used
extern "C" void *vkGetInstanceProcAddr(void *instance, const char *name);

namespace fs = std::filesystem;

namespace {

// ---- The core library ----
struct Core {
    void *handle = nullptr;
    std::string error;
#define AZH_FN(name) decltype(&::name) name = nullptr
    AZH_FN(azh_api_version);
    AZH_FN(azh_version);
    AZH_FN(azh_init);
    AZH_FN(azh_free);
    AZH_FN(azh_game_info_json);
    AZH_FN(azh_game_icon_rgba);
    AZH_FN(azh_install_cia);
    AZH_FN(azh_installed_title_path);
    AZH_FN(azh_installed_titles);
    AZH_FN(azh_uninstall_title);
    AZH_FN(azh_set_setting);
    AZH_FN(azh_boot);
    AZH_FN(azh_surface_changed);
    AZH_FN(azh_set_paused);
    AZH_FN(azh_stop);
    AZH_FN(azh_running);
    AZH_FN(azh_perf);
    AZH_FN(azh_set_buttons);
    AZH_FN(azh_set_stick);
    AZH_FN(azh_touch);
    AZH_FN(azh_set_motion);
#undef AZH_FN
};

std::mutex g_mutex; // library, settings and keys files
std::once_flag g_load_once;
Core g_core;

fs::path root() {
    return fs::path(ios::get_documents_path()) / "3DS";
}
fs::path azahar_dir() {
    return root() / "azahar";
}
fs::path library_dir() {
    return root() / "library";
}
fs::path games_dir() {
    return root() / "games";
}
fs::path keys_dir() {
    return root() / "keys";
}

char *dup_string(const std::string &text) {
    char *out = static_cast<char *>(std::malloc(text.size() + 1));
    std::memcpy(out, text.c_str(), text.size() + 1);
    return out;
}

std::string take(char *text) {
    if (!text)
        return {};
    std::string out(text);
    g_core.azh_free(text);
    return out;
}

std::string json_escape(const std::string &in) {
    std::string out;
    for (const unsigned char c : in) {
        if (c == '"' || c == '\\')
            out += '\\', out += static_cast<char>(c);
        else if (c < 0x20)
            out += ' ';
        else
            out += static_cast<char>(c);
    }
    return out;
}

// A field of the flat JSON objects the core returns
std::string json_field(const std::string &json, const std::string &key) {
    const std::string marker = "\"" + key + "\":";
    auto at = json.find(marker);
    if (at == std::string::npos)
        return {};
    at += marker.size();
    if (at < json.size() && json[at] == '"') {
        std::string out;
        for (size_t i = at + 1; i < json.size() && json[i] != '"'; i++) {
            if (json[i] == '\\' && i + 1 < json.size())
                i++;
            out += json[i];
        }
        return out;
    }
    const auto end = json.find_first_of(",}", at);
    return json.substr(at, end - at);
}

// ---- key=value files (settings, library entries) ----
using Fields = std::map<std::string, std::string>;

Fields read_fields(const fs::path &file) {
    Fields fields;
    std::ifstream in(file);
    std::string line;
    while (std::getline(in, line)) {
        const auto equals = line.find('=');
        if (equals != std::string::npos)
            fields[line.substr(0, equals)] = line.substr(equals + 1);
    }
    return fields;
}

void write_fields(const fs::path &file, const Fields &fields) {
    std::error_code ec;
    fs::create_directories(file.parent_path(), ec);
    const auto temp = fs::path(file).concat(".new");
    {
        std::ofstream out(temp, std::ios::trunc);
        for (const auto &[key, value] : fields)
            out << key << '=' << value << '\n';
    }
    fs::rename(temp, file, ec);
}

// ---- JIT and Vulkan for the core ----
#if defined(__aarch64__)
bool lend_jit(std::size_t size, void **rx, void **rw) {
    return ios_jit_lend_region(size, rx, rw);
}
void take_back_jit(void *rx, void *rw, std::size_t size) {
    ios_jit_take_back_region(rx, rw, size);
}
std::size_t jit_size() {
    return ios_jit_lend_size();
}
#endif

void core_log(int, const char *line) {
    LOG_INFO("[3DS] {}", line ? line : "");
}

void apply_saved_settings() {
    for (const auto &[key, value] : read_fields(root() / "settings.txt"))
        g_core.azh_set_setting(key.c_str(), value.c_str());
}

bool load_core() {
    std::call_once(g_load_once, [] {
        Dl_info info{};
        if (!dladdr(reinterpret_cast<const void *>(&load_core), &info) || !info.dli_fname) {
            g_core.error = "Hinoki could not find its own folder.";
            return;
        }
        const fs::path library = fs::path(info.dli_fname).parent_path() / "Frameworks" / "libazahar_hinoki.dylib";
        std::error_code ec;
        if (!fs::exists(library, ec)) {
            g_core.error = "This build of Hinoki has no 3DS core.";
            LOG_WARN("3DS: {} is missing", library.string());
            return;
        }
        g_core.handle = dlopen(library.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!g_core.handle) {
            const char *why = dlerror();
            g_core.error = fmt::format("The 3DS core could not be loaded ({}).", why ? why : "unknown error");
            LOG_ERROR("3DS: {}", g_core.error);
            return;
        }
        bool complete = true;
        const auto bind = [&](auto &function, const char *name) {
            function = reinterpret_cast<std::remove_reference_t<decltype(function)>>(dlsym(g_core.handle, name));
            if (!function) {
                LOG_ERROR("3DS: the core has no {}", name);
                complete = false;
            }
        };
#define AZH_BIND(name) bind(g_core.name, #name)
        AZH_BIND(azh_api_version);
        AZH_BIND(azh_version);
        AZH_BIND(azh_init);
        AZH_BIND(azh_free);
        AZH_BIND(azh_game_info_json);
        AZH_BIND(azh_game_icon_rgba);
        AZH_BIND(azh_install_cia);
        AZH_BIND(azh_installed_title_path);
        AZH_BIND(azh_installed_titles);
        AZH_BIND(azh_uninstall_title);
        AZH_BIND(azh_set_setting);
        AZH_BIND(azh_boot);
        AZH_BIND(azh_surface_changed);
        AZH_BIND(azh_set_paused);
        AZH_BIND(azh_stop);
        AZH_BIND(azh_running);
        AZH_BIND(azh_perf);
        AZH_BIND(azh_set_buttons);
        AZH_BIND(azh_set_stick);
        AZH_BIND(azh_touch);
        AZH_BIND(azh_set_motion);
#undef AZH_BIND
        if (!complete || g_core.azh_api_version() != AZH_API_VERSION) {
            g_core.error = "The 3DS core in this build doesn't match the app.";
            g_core.handle = nullptr;
            return;
        }

        azh_host host{};
#if defined(__aarch64__)
        host.jit_take = &lend_jit;
        host.jit_return = &take_back_jit;
        host.jit_cache_size = &jit_size;
#endif
        host.vk_get_instance_proc_addr = reinterpret_cast<void *>(&vkGetInstanceProcAddr);
        host.log = &core_log;
        const std::string user = azahar_dir().string() + "/";
        fs::create_directories(azahar_dir(), ec);
        if (!g_core.azh_init(user.c_str(), &host)) {
            g_core.error = "The 3DS core could not start.";
            g_core.handle = nullptr;
            return;
        }
        apply_saved_settings();
        LOG_INFO("3DS: core loaded ({})", g_core.azh_version());
    });
    return g_core.handle != nullptr;
}

// ---- Library ----
std::string id_for(uint64_t title_id, const fs::path &file) {
    if (title_id != 0)
        return fmt::format("{:016X}", title_id);
    return fmt::format("3DSX{:012X}", std::hash<std::string>{}(file.filename().string()) & 0xFFFFFFFFFFFFull);
}

bool valid_id(const std::string &id) {
    return !id.empty() && id.size() <= 32 && std::all_of(id.begin(), id.end(), [](unsigned char c) { return std::isalnum(c); });
}

// The icon (crisp, 3x) and a LiveArea picture: the icon large on a blurred, darkened copy of itself
void write_art(const fs::path &folder, const std::array<uint8_t, 48 * 48 * 4> &icon) {
    std::error_code ec;
    fs::create_directories(folder / "sce_sys", ec);

    constexpr int ICON = 144;
    std::vector<uint8_t> big(ICON * ICON * 4);
    for (int y = 0; y < ICON; y++)
        for (int x = 0; x < ICON; x++)
            std::memcpy(&big[(y * ICON + x) * 4], &icon[((y / 3) * 48 + x / 3) * 4], 4);
    stbi_write_png((folder / "sce_sys/icon0.png").c_str(), ICON, ICON, 4, big.data(), ICON * 4);

    // background: the icon's colours, smoothly blown up and blurred
    constexpr int W = 960, H = 544, SW = 60, SH = 34;
    std::vector<float> small(SW * SH * 3);
    for (int y = 0; y < SH; y++)
        for (int x = 0; x < SW; x++)
            for (int c = 0; c < 3; c++)
                small[(y * SW + x) * 3 + c] = icon[((y * 48 / SH) * 48 + (x * 48 / SW)) * 4 + c];
    for (int pass = 0; pass < 4; pass++) {
        std::vector<float> blurred(small.size());
        for (int y = 0; y < SH; y++)
            for (int x = 0; x < SW; x++)
                for (int c = 0; c < 3; c++) {
                    float sum = 0;
                    int count = 0;
                    for (int dy = -2; dy <= 2; dy++)
                        for (int dx = -2; dx <= 2; dx++) {
                            const int sx = std::clamp(x + dx, 0, SW - 1), sy = std::clamp(y + dy, 0, SH - 1);
                            sum += small[(sy * SW + sx) * 3 + c];
                            count++;
                        }
                    blurred[(y * SW + x) * 3 + c] = sum / count;
                }
        small.swap(blurred);
    }
    std::vector<uint8_t> art(W * H * 4);
    for (int y = 0; y < H; y++) {
        const float fy = std::clamp((y + 0.5f) * SH / H - 0.5f, 0.f, SH - 1.f);
        const int y0 = static_cast<int>(fy), y1 = std::min(y0 + 1, SH - 1);
        for (int x = 0; x < W; x++) {
            const float fx = std::clamp((x + 0.5f) * SW / W - 0.5f, 0.f, SW - 1.f);
            const int x0 = static_cast<int>(fx), x1 = std::min(x0 + 1, SW - 1);
            const float ax = fx - x0, ay = fy - y0;
            // darker towards the edges
            const float dx = (x - W / 2.f) / (W / 2.f), dy = (y - H / 2.f) / (H / 2.f);
            const float shade = 0.55f - 0.2f * std::min(1.f, dx * dx + dy * dy);
            for (int c = 0; c < 3; c++) {
                const float top = small[(y0 * SW + x0) * 3 + c] * (1 - ax) + small[(y0 * SW + x1) * 3 + c] * ax;
                const float bottom = small[(y1 * SW + x0) * 3 + c] * (1 - ax) + small[(y1 * SW + x1) * 3 + c] * ax;
                art[(y * W + x) * 4 + c] = static_cast<uint8_t>(std::clamp((top * (1 - ay) + bottom * ay) * shade, 0.f, 255.f));
            }
            art[(y * W + x) * 4 + 3] = 255;
        }
    }
    constexpr int SCALE = 5, SIZE = 48 * SCALE;
    const int left = (W - SIZE) / 2, top = (H - SIZE) / 2 - 20;
    for (int y = 0; y < SIZE; y++)
        for (int x = 0; x < SIZE; x++) {
            const uint8_t *src = &icon[((y / SCALE) * 48 + x / SCALE) * 4];
            std::memcpy(&art[((top + y) * W + left + x) * 4], src, 4);
        }
    stbi_write_png((folder / "sce_sys/pic0.png").c_str(), W, H, 4, art.data(), W * 4);
}

// Records a game in the library (info.txt plus art)
void add_to_library(const std::string &id, const std::string &kind, const fs::path &file, uint64_t title_id, const std::string &info_json) {
    const fs::path folder = library_dir() / id;
    Fields fields = read_fields(folder / "info.txt");
    fields["id"] = id;
    fields["kind"] = kind;
    fields["file"] = kind == "installed" ? "" : file.string();
    fields["title_id"] = fmt::format("{:016X}", title_id);
    std::string title = json_field(info_json, "title");
    if (title.empty())
        title = file.stem().string();
    fields["title"] = title;
    fields["publisher"] = json_field(info_json, "publisher");
    fields["regions"] = json_field(info_json, "regions");
    fields.try_emplace("last_played", "0");
    fields.try_emplace("play_time", "0");
    write_fields(folder / "info.txt", fields);

    std::array<uint8_t, 48 * 48 * 4> icon{};
    const fs::path run_path = kind == "installed" ? fs::path(take(g_core.azh_installed_title_path(title_id))) : file;
    if (!run_path.empty() && g_core.azh_game_icon_rgba(run_path.c_str(), icon.data())) {
        write_art(folder, icon);
    } else {
        // no icon (homebrew without one): a plain tile
        for (size_t i = 0; i < icon.size(); i += 4) {
            icon[i] = 0x2B;
            icon[i + 1] = 0x4A;
            icon[i + 2] = 0x3C;
            icon[i + 3] = 0xFF;
        }
        write_art(folder, icon);
    }
}

bool copy_with_progress(const fs::path &from, const fs::path &to, const std::function<void(float)> &progress, float begin, float end) {
    std::ifstream in(from, std::ios::binary);
    std::ofstream out(to, std::ios::binary | std::ios::trunc);
    if (!in || !out)
        return false;
    std::error_code ec;
    const auto total = fs::file_size(from, ec);
    std::vector<char> buffer(8 * 1024 * 1024);
    uint64_t done = 0;
    while (in) {
        in.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        const auto got = in.gcount();
        if (got <= 0)
            break;
        out.write(buffer.data(), got);
        if (!out)
            return false;
        done += static_cast<uint64_t>(got);
        if (progress && total)
            progress(begin + (end - begin) * static_cast<float>(done) / static_cast<float>(total));
    }
    return static_cast<bool>(out);
}

bool inside(const fs::path &file, const fs::path &folder) {
    const auto relative = fs::weakly_canonical(file).lexically_relative(fs::weakly_canonical(folder));
    return !relative.empty() && *relative.begin() != "..";
}

struct LoadedKeys {
    n3ds::Keys keys;
    n3ds::SeedDb seeds;
    int count = 0;
};

LoadedKeys load_keys() {
    LoadedKeys loaded;
    loaded.count = loaded.keys.load(keys_dir() / "aes_keys.txt");
    loaded.seeds = n3ds::load_seeddb(keys_dir() / "seeddb.bin");
    return loaded;
}

std::string kind_of_title(uint64_t title_id) {
    switch (static_cast<uint32_t>(title_id >> 32)) {
    case 0x00040000: return "game";
    case 0x0004000E: return "update";
    case 0x0004008C: return "dlc";
    case 0x00040002: return "demo";
    default: return "system";
    }
}

} // namespace

namespace n3ds {

bool is_3ds_file(const fs::path &path) {
    std::string ext = path.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return std::tolower(c); });
    static const std::array<std::string, 13> extensions{ ".3ds", ".cci", ".cxi", ".cia", ".3dsx", ".app", ".elf", ".axf",
        ".zcci", ".zcxi", ".zcia", ".z3dsx", ".z3ds" };
    if (std::find(extensions.begin(), extensions.end(), ext) == extensions.end())
        return false;
    // .elf and .app are common names: only when they really are 3DS files
    if (ext == ".elf" || ext == ".axf" || ext == ".app")
        return probe(path).kind != FileKind::Unknown;
    return true;
}

bool import_file(const fs::path &path, const std::function<void(float)> &progress, std::string &result) {
    if (!load_core()) {
        result = g_core.error;
        return false;
    }
    std::error_code ec;
    fs::create_directories(games_dir(), ec);
    fs::create_directories(root() / "tmp", ec);
    const Probe info = probe(path);
    const auto report = [&](float value) {
        if (progress)
            progress(std::clamp(value, 0.f, 100.f));
    };

    LoadedKeys keys;
    if (info.encrypted) {
        keys = load_keys();
        if (!keys.keys.has_ncch() && !(info.kind == FileKind::CIA && keys.keys.has_ticket())) {
            result = "This game is encrypted. Add your 3DS keys first (Settings › 3DS › Keys: aes_keys.txt from your console, "
                     "and seeddb.bin for newer games), then import it again.";
            return false;
        }
    }

    if (info.kind == FileKind::CIA) {
        fs::path cia = path;
        fs::path temp;
        if (info.encrypted) {
            temp = root() / "tmp" / path.filename();
            if (!copy_with_progress(path, temp, report, 0, 30)) {
                result = "The CIA could not be copied (is there enough free space?).";
                fs::remove(temp, ec);
                return false;
            }
            const std::string error = decrypt_in_place(temp, keys.keys, keys.seeds,
                [&](uint64_t done, uint64_t total) { report(30 + 40.f * static_cast<float>(done) / static_cast<float>(std::max<uint64_t>(total, 1))); });
            if (!error.empty()) {
                fs::remove(temp, ec);
                result = "This CIA could not be decrypted: " + error + ".";
                return false;
            }
            cia = temp;
        }
        struct Context {
            std::function<void(float)> report;
            float begin;
        } context{ report, info.encrypted ? 70.f : 0.f };
        uint64_t title_id = 0;
        const int status = g_core.azh_install_cia(
            cia.c_str(), [](void *ctx, uint64_t done, uint64_t total) {
                auto *c = static_cast<Context *>(ctx);
                c->report(c->begin + (100.f - c->begin) * static_cast<float>(done) / static_cast<float>(std::max<uint64_t>(total, 1)));
            },
            &context, &title_id);
        if (!temp.empty())
            fs::remove(temp, ec);
        if (status != 0) {
            static const std::map<int, std::string> reasons{ { 1, "it could not be opened" }, { 2, "the file was not found" },
                { 3, "it was cancelled" }, { 4, "it is not a valid CIA" }, { 5, "it is encrypted" } };
            const auto reason = reasons.find(status);
            result = "The CIA could not be installed: " + (reason != reasons.end() ? reason->second : "error " + std::to_string(status)) + ".";
            return false;
        }
        const std::string kind = kind_of_title(title_id);
        if (kind == "update" || kind == "dlc") {
            const auto game = library_dir() / fmt::format("{:016X}", (title_id & 0xFFFFFFFFull) | (0x00040000ull << 32));
            const std::string game_title = read_fields(game / "info.txt")["title"];
            result = fmt::format("{} installed{}.", kind == "update" ? "Update" : "DLC", game_title.empty() ? "" : " for " + game_title);
            return true;
        }
        const std::string installed = take(g_core.azh_installed_title_path(title_id));
        const std::string json = take(g_core.azh_game_info_json(installed.c_str()));
        std::lock_guard lock(g_mutex);
        add_to_library(id_for(title_id, path), "installed", installed, title_id, json);
        result = fmt::format("{} installed.", json_field(json, "title").empty() ? path.filename().string() : json_field(json, "title"));
        return true;
    }

    // Cartridge dumps and homebrew: kept as files in 3DS/games
    fs::path dest = games_dir() / path.filename();
    if (fs::equivalent(path, dest, ec)) {
        // already there
    } else if (inside(path, fs::path(ios::get_documents_path()))) {
        fs::rename(path, dest, ec); // the app's own folder (Import): move, don't copy
        if (ec && !copy_with_progress(path, dest, report, 0, info.encrypted ? 50.f : 100.f)) {
            result = "The game could not be copied (is there enough free space?).";
            return false;
        }
    } else if (!copy_with_progress(path, dest, report, 0, info.encrypted ? 50.f : 100.f)) {
        fs::remove(dest, ec);
        result = "The game could not be copied (is there enough free space?).";
        return false;
    }
    if (info.encrypted) {
        const std::string error = decrypt_in_place(dest, keys.keys, keys.seeds,
            [&](uint64_t done, uint64_t total) { report(50 + 50.f * static_cast<float>(done) / static_cast<float>(std::max<uint64_t>(total, 1))); });
        if (!error.empty()) {
            fs::remove(dest, ec);
            result = "This game could not be decrypted: " + error + ".";
            return false;
        }
    }
    const std::string json = take(g_core.azh_game_info_json(dest.c_str()));
    if (json_field(json, "ok") != "true") {
        fs::remove(dest, ec);
        result = "This is not a 3DS game Hinoki can run.";
        return false;
    }
    if (json_field(json, "encrypted") == "true") {
        fs::remove(dest, ec);
        result = "This game is still encrypted: add your keys (Settings › 3DS › Keys) and import it again.";
        return false;
    }
    const uint64_t title_id = std::strtoull(json_field(json, "titleId").c_str(), nullptr, 16);
    const bool homebrew = info.kind == FileKind::ThreeDSX || info.kind == FileKind::ELF || json_field(json, "kind") == "homebrew";
    const std::string id = id_for(homebrew ? 0 : title_id, dest);
    std::lock_guard lock(g_mutex);
    add_to_library(id, homebrew ? "homebrew" : "cart", dest, title_id, json);
    const std::string title = json_field(json, "title");
    result = fmt::format("{} added{}.", title.empty() ? dest.filename().string() : title, info.encrypted ? " (decrypted with your keys)" : "");
    return true;
}

} // namespace n3ds

using namespace n3ds;

extern "C" {

bool v3k_n3ds_available(void) {
    return load_core();
}

char *v3k_n3ds_status(void) {
    if (!load_core())
        return dup_string(g_core.error);
    return dup_string(fmt::format("Azahar {}", g_core.azh_version()));
}

char *v3k_n3ds_apps_json(void) {
    std::lock_guard lock(g_mutex);
    std::string json;
    std::error_code ec;
    for (const auto &entry : fs::directory_iterator(library_dir(), ec)) {
        if (!entry.is_directory())
            continue;
        const Fields fields = read_fields(entry.path() / "info.txt");
        const auto get = [&](const char *key) {
            const auto it = fields.find(key);
            return it != fields.end() ? it->second : std::string{};
        };
        const std::string id = get("id");
        if (id.empty())
            continue;
        // gone? (a cartridge file deleted in the Files app)
        if (get("kind") != "installed" && !fs::exists(get("file"), ec))
            continue;
        const fs::path icon = entry.path() / "sce_sys/icon0.png";
        json += fmt::format(R"({}{{"titleId":"{}","title":"{}","version":"{}","category":"3ds","iconPath":"{}","path":"{}","lastPlayed":{},"playTime":{},"customConfig":false,"compat":-1,"compatIssue":0}})",
            json.empty() ? "" : ",", json_escape(id), json_escape(get("title")), get("kind") == "homebrew" ? "Homebrew" : "3DS",
            json_escape(icon.string()), json_escape(entry.path().string()), std::atoll(get("last_played").c_str()), std::atoll(get("play_time").c_str()));
    }
    return dup_string(json);
}

char *v3k_n3ds_game_path(const char *id) {
    if (!id || !valid_id(id))
        return nullptr;
    const Fields fields = read_fields(library_dir() / id / "info.txt");
    const auto kind = fields.find("kind");
    if (kind == fields.end())
        return nullptr;
    if (kind->second == "installed") {
        if (!load_core())
            return nullptr;
        const auto title = fields.find("title_id");
        const uint64_t title_id = title != fields.end() ? std::strtoull(title->second.c_str(), nullptr, 16) : 0;
        const std::string path = take(g_core.azh_installed_title_path(title_id));
        return path.empty() ? nullptr : dup_string(path);
    }
    const auto file = fields.find("file");
    return file != fields.end() && !file->second.empty() ? dup_string(file->second) : nullptr;
}

bool v3k_n3ds_remove(const char *id) {
    if (!id || !valid_id(id))
        return false;
    std::lock_guard lock(g_mutex);
    const fs::path folder = library_dir() / id;
    const Fields fields = read_fields(folder / "info.txt");
    std::error_code ec;
    const auto kind = fields.find("kind");
    if (kind != fields.end() && kind->second == "installed") {
        if (load_core()) {
            const auto title = fields.find("title_id");
            if (title != fields.end())
                g_core.azh_uninstall_title(std::strtoull(title->second.c_str(), nullptr, 16));
        }
    } else if (const auto file = fields.find("file"); file != fields.end() && inside(file->second, games_dir())) {
        fs::remove(file->second, ec);
    }
    fs::remove_all(folder, ec);
    return true;
}

bool v3k_n3ds_import_keys(const char *path_c, char **message) {
    std::string result;
    bool ok = false;
    if (path_c) {
        std::lock_guard lock(g_mutex);
        const fs::path path(path_c);
        std::error_code ec;
        fs::create_directories(keys_dir(), ec);
        std::vector<fs::path> files;
        if (fs::is_directory(path, ec)) {
            for (const auto &entry : fs::recursive_directory_iterator(path, ec)) {
                if (entry.is_regular_file())
                    files.push_back(entry.path());
            }
        } else {
            files.push_back(path);
        }
        int key_files = 0, seed_files = 0;
        for (const auto &file : files) {
            std::string name = file.filename().string();
            std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return std::tolower(c); });
            if (name == "seeddb.bin") {
                if (!load_seeddb(file).empty()) {
                    fs::copy_file(file, keys_dir() / "seeddb.bin", fs::copy_options::overwrite_existing, ec);
                    fs::create_directories(azahar_dir() / "sysdata", ec);
                    fs::copy_file(file, azahar_dir() / "sysdata/seeddb.bin", fs::copy_options::overwrite_existing, ec);
                    seed_files++;
                }
            } else if (file.extension() == ".txt") {
                Keys keys;
                if (keys.load(file) > 0) {
                    // merged with what's there (some people keep the slots in separate files)
                    const fs::path target = keys_dir() / "aes_keys.txt";
                    std::string existing;
                    {
                        std::ifstream in(target);
                        existing.assign(std::istreambuf_iterator<char>(in), {});
                    }
                    std::ifstream in(file);
                    std::string added((std::istreambuf_iterator<char>(in)), {});
                    std::ofstream out(target, std::ios::trunc);
                    out << existing << (existing.empty() || existing.back() == '\n' ? "" : "\n") << added << '\n';
                    key_files++;
                }
            }
        }
        const auto loaded = load_keys();
        if (key_files == 0 && seed_files == 0) {
            result = "No 3DS keys were found there. Pick aes_keys.txt (GodMode9 › Scripts or [0:]/gm9/support) or seeddb.bin.";
        } else {
            ok = true;
            result = fmt::format("{}{}{}", key_files ? "Keys added. " : "", seed_files ? fmt::format("{} seeds added. ", loaded.seeds.size()) : "",
                loaded.keys.has_ncch() ? "Encrypted games and CIAs can be imported now." : "Still missing: slot0x2CKeyX (the main game key).");
        }
    }
    if (message)
        *message = dup_string(result);
    return ok;
}

char *v3k_n3ds_keys_json(void) {
    std::lock_guard lock(g_mutex);
    const auto loaded = load_keys();
    return dup_string(fmt::format(R"({{"aesKeys":{},"ncch":{},"ticket":{},"seeds":{},"summary":"{}"}})", loaded.count > 0 ? "true" : "false",
        loaded.keys.has_ncch() ? "true" : "false", loaded.keys.has_ticket() ? "true" : "false", loaded.seeds.size(),
        json_escape(loaded.count > 0 ? loaded.keys.summary() : "")));
}

bool v3k_n3ds_remove_keys(void) {
    std::lock_guard lock(g_mutex);
    std::error_code ec;
    fs::remove_all(keys_dir(), ec);
    return !ec;
}

void v3k_n3ds_set_setting(const char *key, const char *value) {
    if (!key || !value)
        return;
    {
        std::lock_guard lock(g_mutex);
        Fields fields = read_fields(root() / "settings.txt");
        fields[key] = value;
        write_fields(root() / "settings.txt", fields);
    }
    if (g_core.handle)
        g_core.azh_set_setting(key, value);
}

void v3k_n3ds_clear_shader_cache(void) {
    std::error_code ec;
    fs::remove_all(azahar_dir() / "shaders", ec);
}

bool v3k_n3ds_boot(const char *id, void *metal_layer, int width, int height, float scale, bool portrait, v3k_n3ds_event_fn events, void *context) {
    if (!load_core())
        return false;
    char *path = v3k_n3ds_game_path(id);
    if (!path)
        return false;
    const std::string file(path);
    std::free(path);
    // Code caches Vita games left in their pool go back to the shared pool first
    flush_cpu_pool();
    apply_saved_settings();
    {
        std::lock_guard lock(g_mutex);
        Fields fields = read_fields(library_dir() / id / "info.txt");
        fields["last_played"] = std::to_string(std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count());
        write_fields(library_dir() / id / "info.txt", fields);
    }
    LOG_INFO("3DS: starting {} ({}), {}x{} {}", id, file, width, height, portrait ? "portrait" : "landscape");
    return g_core.azh_boot(file.c_str(), metal_layer, width, height, scale, portrait, events, context);
}

void v3k_n3ds_surface_changed(int width, int height, float scale, bool portrait) {
    if (g_core.handle)
        g_core.azh_surface_changed(width, height, scale, portrait);
}

void v3k_n3ds_set_paused(bool paused) {
    if (g_core.handle)
        g_core.azh_set_paused(paused);
}

void v3k_n3ds_stop(void) {
    if (g_core.handle)
        g_core.azh_stop();
}

bool v3k_n3ds_running(void) {
    return g_core.handle && g_core.azh_running();
}

void v3k_n3ds_perf(double *fps, double *speed) {
    if (g_core.handle)
        g_core.azh_perf(fps, speed);
}

void v3k_n3ds_set_buttons(uint32_t mask) {
    if (g_core.handle)
        g_core.azh_set_buttons(mask);
}

void v3k_n3ds_set_stick(int stick, float x, float y) {
    if (g_core.handle)
        g_core.azh_set_stick(stick, x, y);
}

void v3k_n3ds_touch(int phase, float x, float y) {
    if (g_core.handle)
        g_core.azh_touch(phase, x, y);
}

void v3k_n3ds_set_motion(float gx, float gy, float gz, float ax, float ay, float az) {
    if (g_core.handle)
        g_core.azh_set_motion(gx, gy, gz, ax, ay, az);
}

void v3k_n3ds_session_ended(const char *id, double seconds) {
    if (!id || !valid_id(id) || seconds <= 0)
        return;
    std::lock_guard lock(g_mutex);
    Fields fields = read_fields(library_dir() / id / "info.txt");
    if (fields.empty())
        return;
    fields["play_time"] = std::to_string(std::atoll(fields["play_time"].c_str()) + static_cast<long long>(seconds));
    write_fields(library_dir() / id / "info.txt", fields);
}

} // extern "C"
