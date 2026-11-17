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

// Hinoki's 3DS side: loads the Azahar core (Frameworks/libazahar_hinoki.dylib, built from
// vita3k/ios/n3ds/azahar), keeps the 3DS library and keys, and lends the core JIT memory and the
// app's MoltenVK. Plain C so Swift can call it.
//
// Files live in Documents/3DS: azahar/ (Azahar's own folder: saves, installed titles, shaders),
// games/ (imported cartridge dumps), library/<id>/ (icon, art, info per game), keys/.

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The core is in the app and loaded (loads it on first call)
bool v3k_n3ds_available(void);
// Why not, or the core's version. Free with v3k_free_string
char *v3k_n3ds_status(void);

// Games, as the app list's JSON objects (same fields as v3k_apps_json, category "3ds"), comma
// separated without brackets. Empty when there are none. Free with v3k_free_string
char *v3k_n3ds_apps_json(void);
bool v3k_n3ds_remove(const char *id);
// Downloads box art (GameTDB) for games that have none yet; slow, run off the main thread. true when
// some was added
bool v3k_n3ds_fetch_art(void);
// The file a game runs from, or NULL. Free with v3k_free_string
char *v3k_n3ds_game_path(const char *id);

// Keys from the player's console: aes_keys.txt and seeddb.bin (a file, or a folder/zip holding
// them). *message gets a summary to free with v3k_free_string.
bool v3k_n3ds_import_keys(const char *path, char **message);
// {"aesKeys":bool,"ncch":bool,"ticket":bool,"seeds":n,"summary":"..."}
char *v3k_n3ds_keys_json(void);
bool v3k_n3ds_remove_keys(void);

// Settings by Azahar's names (see azh_set_setting); remembered and sent before every boot
void v3k_n3ds_set_setting(const char *key, const char *value);
void v3k_n3ds_clear_shader_cache(void);

// Running a game (see hinoki_azahar.h for the events)
typedef void (*v3k_n3ds_event_fn)(void *context, int kind, int a, int b, const char *text);
bool v3k_n3ds_boot(const char *id, void *metal_layer, int width, int height, float scale, bool portrait,
    v3k_n3ds_event_fn events, void *context);
void v3k_n3ds_surface_changed(int width, int height, float scale, bool portrait);
void v3k_n3ds_set_paused(bool paused);
void v3k_n3ds_stop(void);
bool v3k_n3ds_running(void);
void v3k_n3ds_perf(double *fps, double *speed);
void v3k_n3ds_set_buttons(uint32_t mask);
void v3k_n3ds_set_stick(int stick, float x, float y);
void v3k_n3ds_touch(int phase, float x, float y);
void v3k_n3ds_set_motion(float gx, float gy, float gz, float ax, float ay, float az);
// Adds play time when a session ends
void v3k_n3ds_session_ended(const char *id, double seconds);

#ifdef __cplusplus
}

#include <filesystem>
#include <functional>
#include <string>

namespace n3ds {
// .3ds .cci .cxi .cia .3dsx .elf .app and Azahar's compressed .zcci .zcxi .zcia .z3dsx
bool is_3ds_file(const std::filesystem::path &path);
// Imports a game, update, DLC or homebrew: decrypts it with the player's keys when needed, installs
// CIAs into the core, copies cartridge dumps, and adds the game to the library. result: what
// happened, in plain words.
bool import_file(const std::filesystem::path &path, const std::function<void(float)> &progress, std::string &result);
} // namespace n3ds
#endif
