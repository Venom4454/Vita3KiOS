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

#include "ios_session.h"
#include "archive.h"
#include "bridge/vita3k_bridge.h"
#include "crash_report.h"
#include "n3ds/n3ds.h"

#include <compat/functions.h>
#include <compat/state.h>
#include <config/functions.h>
#include <config/settings.h>
#include <config/version.h>
#include <modules/module_parent.h>
#include <packages/functions.h>
#include <packages/pkg.h>
#include <renderer/functions.h>
#include <util/log.h>
#include <util/string_utils.h>
#include <util/sysinfo.h>

#include <SDL3/SDL.h>
#include <fmt/format.h>

#include <algorithm>
#include <cctype>
#include <fstream>

namespace ios {

SessionState &session_state() {
    static SessionState state;
    return state;
}

EmuEnvState *get_emuenv() {
    return session_state().emuenv.get();
}

app::AppSessionController *get_app_session_controller() {
    return session_state().app_session_controller.get();
}

namespace {
fs::path documents_root;
bool custom_storage = false;
std::string custom_storage_note;

// The storage location is owned by the app (a bookmark), not config.yml: an absolute pref-path there
// breaks start-up whenever the container moves or a drive is unplugged
void remove_saved_pref_path(const fs::path &config_dir) {
    const fs::path config_file = config_dir / "config.yml";
    std::ifstream in(config_file);
    if (!in)
        return;
    std::string content, line;
    bool changed = false;
    while (std::getline(in, line)) {
        if (line.rfind("pref-path:", 0) == 0) {
            changed = true;
            continue;
        }
        content += line + "\n";
    }
    in.close();
    if (changed)
        std::ofstream(config_file, std::ios::trunc) << content;
}
} // namespace

fs::path internal_vita_root() {
    return documents_root / "vita";
}

fs::path vita_root_for(const fs::path &picked_folder) {
    std::error_code ec;
    if (fs::is_directory(picked_folder / "ux0", ec))
        return picked_folder;
    return picked_folder / "Vita3K";
}

bool using_custom_storage() {
    return custom_storage;
}

std::string storage_note() {
    return custom_storage_note;
}

bool initialize(const fs::path &storage_path) {
    auto &session = session_state();
    if (session.emuenv)
        return true;

    documents_root = storage_path;
    fs::path vita_root = internal_vita_root();
    const std::string custom = resolve_custom_storage(custom_storage_note);
    if (!custom.empty()) {
        std::error_code ec;
        const fs::path root = vita_root_for(fs::path(custom));
        fs::create_directories(root, ec);
        if (!ec) {
            vita_root = root;
            custom_storage = true;
        } else {
            custom_storage_note = "Could not use the custom storage folder (" + ec.message() + "). Using internal storage.";
        }
    }
    remove_saved_pref_path(storage_path);

    try {
        Root root_paths;
        // The bundle holds data/ and shaders-builtin/ at its root
        root_paths.set_static_assets_path(fs::path(get_bundle_resources_path()));
        root_paths.set_vita_fs_path(vita_root);
        root_paths.set_log_path(storage_path);
        root_paths.set_config_path(storage_path);
        root_paths.set_shared_path(storage_path);
        root_paths.set_cache_path(storage_path / "cache");
        root_paths.set_patch_path(storage_path / "patch");

        fs::create_directories(root_paths.get_vita_fs_path());
        fs::create_directories(root_paths.get_config_path());
        fs::create_directories(root_paths.get_cache_path());
        fs::create_directories(root_paths.get_log_path() / "shaderlog");
        fs::create_directories(root_paths.get_log_path() / "texturelog");
        fs::create_directories(root_paths.get_patch_path());
        fs::create_directories(root_paths.get_shared_path() / "textures");

        crash::init(storage_path.string());
        // No console on iOS: the log goes to vita3k.log only, sparing a write per line
        if (logging::init(root_paths, false) != Success)
            return false;

        LOG_INFO("{}", window_title);
        LOG_INFO("OS: {}", get_os_version());
        LOG_INFO("Device: {}", get_device_model());
        LOG_INFO("CPU: {}", util::get_system_info());
        LOG_INFO("Available ram memory: {} MiB", SDL_GetSystemRAM());

        auto emuenv = std::make_unique<EmuEnvState>();

        Config cfg{};
        char arg0[] = "vita3k";
        char *argv[] = { arg0, nullptr };
        if (config::init_config(cfg, 1, argv, root_paths, false) != Success) {
            LOG_ERROR("Failed to initialise config.");
            return false;
        }

        fs::create_directories(cfg.get_vita_fs_path());

        // Trace logging (the desktop default) writes every file access and costs a lot of speed on a
        // phone: use info unless a quieter level was chosen
        if (cfg.log_level < static_cast<int>(spdlog::level::info)) {
            cfg.log_level = static_cast<int>(spdlog::level::info);
            logging::set_level(spdlog::level::info);
            LOG_INFO("log-level: info (iOS default)");
        }

        if (!app::init(*emuenv, cfg, root_paths)) {
            LOG_ERROR("Failed to initialise emulated environment.");
            return false;
        }

        emuenv->vulkan_device_info = std::make_unique<renderer::VulkanDeviceInfo>(renderer::enumerate_vulkan_devices());

        init_libraries(*emuenv);

        if (!app::init_apps_list(*emuenv))
            LOG_ERROR("Failed to initialise apps list.");

        app::load_users(*emuenv);
        if (!app::ensure_current_user(*emuenv)) {
            LOG_ERROR("Failed to initialize active user.");
            return false;
        }
        compat::load_from_disk(emuenv->compat, std::filesystem::path(emuenv->cache_path.string()));

        session.root_paths = std::move(root_paths);
        session.emuenv = std::move(emuenv);
        session.app_session_controller = std::make_unique<app::AppSessionController>(*session.emuenv);
        LOG_INFO("Vita3K iOS initialised. Storage: {}{}", session.emuenv->vita_fs_path, custom_storage ? " (custom)" : "");
        if (!custom_storage_note.empty())
            LOG_WARN("{}", custom_storage_note);
        return true;
    } catch (const std::exception &error) {
        LOG_ERROR("Failed to initialize iOS storage path '{}': {}", storage_path, error.what());
        return false;
    }
}

bool switch_storage(const fs::path &vita_root, bool custom, std::string &message) {
    auto *emuenv = get_emuenv();
    if (!emuenv) {
        message = "The emulator is not initialised.";
        return false;
    }
    std::error_code ec;
    fs::create_directories(vita_root, ec);
    if (ec) {
        message = "Can't create the folder there: " + ec.message();
        return false;
    }

    // Bring the firmware along, so games run without installing it again
    const fs::path current = emuenv->vita_fs_path;
    int copied = 0;
    if (fs::path(current) != vita_root) {
        for (const char *partition : { "os0", "pd0", "sa0", "vs0" }) {
            const fs::path from = current / partition;
            const fs::path to = vita_root / partition;
            if (!fs::exists(from, ec) || fs::exists(to, ec))
                continue;
            fs::copy(from, to, fs::copy_options::recursive, ec);
            if (ec) {
                LOG_WARN("Could not copy {} to the new storage: {}", partition, ec.message());
                ec.clear();
            } else {
                copied++;
            }
        }
    }

    if (!app::switch_emulator_path(*emuenv, vita_root)) {
        message = "Vita3K couldn't use that folder.";
        return false;
    }
    app::scan_apps(*emuenv);
    custom_storage = custom;
    custom_storage_note.clear();
    LOG_INFO("Storage switched to {}{}", vita_root, custom ? " (custom)" : "");

    const auto space = fs::space(vita_root, ec);
    message = copied > 0 ? "Storage location changed. Firmware was copied there." : "Storage location changed.";
    if (!ec)
        message += fmt::format(" {:.1f} GB free.", static_cast<double>(space.available) / 1e9);
    return true;
}

std::vector<app::AppEntry> list_apps() {
    auto *emuenv = get_emuenv();
    if (!emuenv)
        return {};
    return app::get_apps(*emuenv);
}

std::optional<app::AppEntry> find_app_by_title_id(const std::string &title_id) {
    const auto apps = list_apps();
    const auto it = std::ranges::find_if(apps, [&](const app::AppEntry &app) { return app.title_id == title_id; });
    if (it == apps.end())
        return std::nullopt;
    return *it;
}

namespace {

std::string lower_extension(const fs::path &path) {
    return string_utils::tolower(path.extension().string());
}

// A package's zRIF license is read from a text file next to it with the same name: GAME.pkg + GAME.zrif
std::string read_zrif_for(const fs::path &pkg_path) {
    fs::path zrif_path = pkg_path;
    zrif_path.replace_extension(".zrif");
    std::ifstream file(zrif_path);
    if (!file)
        return {};
    std::string zrif;
    std::getline(file, zrif);
    zrif.erase(std::remove_if(zrif.begin(), zrif.end(), [](unsigned char c) { return std::isspace(c); }), zrif.end());
    return zrif;
}

void move_into(const fs::path &file, const fs::path &dir) {
    std::error_code ec;
    fs::create_directories(dir, ec);
    fs::rename(file, dir / file.filename(), ec);
    if (ec)
        LOG_WARN("Could not move {} into {}: {}", file, dir, ec.message());
}

} // namespace

ImportResult import_pending_files(const fs::path &import_dir) {
    ImportResult result;
    auto *emuenv = get_emuenv();
    if (!emuenv)
        return result;

    std::error_code ec;
    fs::create_directories(import_dir, ec);

    std::vector<fs::path> files;
    for (const auto &entry : fs::directory_iterator(import_dir, ec)) {
        if (entry.is_regular_file())
            files.push_back(entry.path());
    }
    // Firmware first, so that apps installed in the same pass find it
    std::ranges::stable_sort(files, [](const fs::path &a, const fs::path &b) {
        return (lower_extension(a) == ".pup") > (lower_extension(b) == ".pup");
    });

    bool installed_any = false;
    for (const auto &file : files) {
        const auto ext = lower_extension(file);
        const auto name = file.filename().string();
        bool handled = true;
        bool ok = false;

        if (ext == ".pup") {
            LOG_INFO("Installing firmware {}", name);
            ok = !install_pup(emuenv->vita_fs_path, file).empty();
        } else if (ext == ".zip" && v3k_install_is_save(file.string().c_str())) {
            // a game's save: put in place like Game settings › Import save data
            char *text = nullptr;
            ok = v3k_import_save_data_auto(file.string().c_str(), &text);
            LOG_INFO("{}: {}", name, text ? text : "");
            std::free(text);
        } else if (ext == ".vpk" || ext == ".zip") {
            LOG_INFO("Installing archive {}", name);
            const auto reinstall = [](const std::string &, const std::string &) { return true; };
            // a list comes back even when nothing installed: count only what did
            const auto contents = install_archive(*emuenv, file, nullptr, reinstall);
            ok = std::ranges::any_of(contents, [](const auto &content) { return content.state; });
            for (const auto &content : contents) {
                if (!content.state && !content.error.empty())
                    LOG_ERROR("{}: {}", name, content.error);
            }
        } else if (ext == ".pkg") {
            LOG_INFO("Installing package {}", name);
            std::string zrif = read_zrif_for(file);
            ok = install_pkg(file, *emuenv, zrif);
        } else if (n3ds::is_3ds_file(file)) {
            LOG_INFO("Importing 3DS file {}", name);
            std::string message;
            ok = n3ds::import_file(file, nullptr, message);
            LOG_INFO("{}: {}", name, message);
            if (ok && !std::filesystem::exists(file))
                continue; // moved into the 3DS library
        } else if (ext == ".suprx" || ext == ".skprx") {
            LOG_INFO("Adding plugin {}", name);
            ok = v3k_add_plugin(file.string().c_str(), nullptr, nullptr);
        } else {
            handled = false; // .zrif files and anything unknown stay where they are
        }

        if (!handled)
            continue;

        if (ok) {
            installed_any = true;
            result.installed.push_back(name);
            move_into(file, import_dir / "done");
        } else {
            LOG_ERROR("Failed to install {}", name);
            result.failed.push_back(name);
            move_into(file, import_dir / "failed");
        }
    }

    if (installed_any)
        app::scan_apps(*emuenv);

    return result;
}

} // namespace ios
