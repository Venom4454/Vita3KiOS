// Hinoki: the 3DS side, built from Azahar (https://github.com/azahar-emu/azahar, GPLv2+) as a dynamic
// library that Hinoki loads at run time. Azahar's own libraries stay inside it (it exports only these
// functions), so its copies of dynarmic, fmt, boost and the rest never meet Vita3K's.
//
// Plain C, so both the library and Hinoki (C++ and Swift) can include it.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AZH_API_VERSION 4

// What Hinoki lends the core
typedef struct azh_host {
    // JIT code memory from Hinoki's pool (iOS 26: regions StikDebug prepared up front). take returns
    // false when it has none, and the core then asks iOS directly (works on older iOS only).
    bool (*jit_take)(size_t size, void **rx, void **rw);
    void (*jit_return)(void *rx, void *rw, size_t size);
    // The code cache size to ask for next (a size the pool holds), 0 for the core's default
    size_t (*jit_cache_size)(void);
    // vkGetInstanceProcAddr of the MoltenVK linked into Hinoki (one Vulkan driver per app)
    void *vk_get_instance_proc_addr;
    // One line of the core's log (level 0 trace ... 5 critical), also written to log/azahar_log.txt
    void (*log)(int level, const char *line);
} azh_host;

// Converting a cartridge dump or homebrew file to Azahar's compressed format (.zcci .zcxi .zcia .z3dsx,
// zstd in seekable frames: plays as it is) or back. Writes next to the original, which stays: the
// caller removes it. dst_out gets the new file's path. Slow: not on the main thread
typedef void (*azh_progress_fn)(void *context, uint64_t done, uint64_t total);
enum {
    AZH_CONVERT_OK = 0,
    AZH_CONVERT_UNSUPPORTED = 1, // installed, encrypted, or a kind of file Azahar can't pack
    AZH_CONVERT_ALREADY = 2,
    AZH_CONVERT_NOT_COMPRESSED = 3,
    AZH_CONVERT_FAILED = 4,
};
int azh_convert_rom(const char *src, bool compress, azh_progress_fn progress, void *context, char *dst_out, size_t dst_size);

int azh_api_version(void);
// The Azahar version this library was built from
const char *azh_version(void);

// Once, before anything else. user_dir ends with '/': Azahar's user folder (sdmc, nand, sysdata,
// config, shaders, log...)
bool azh_init(const char *user_dir, const azh_host *host);

// Strings returned by the library: free with azh_free
void azh_free(char *string);

// What a file is, without running it:
// {"ok":bool,"type":"CCI|CXI|CIA|3DSX|ELF|...","titleId":"0004000000055D00","title","publisher",
//  "encrypted":bool,"executable":bool,"kind":"game|update|dlc|system|homebrew","regions":"..."}
char *azh_game_info_json(const char *path);
// The 48x48 icon as RGBA (48*48*4 bytes). false when the file has none
bool azh_game_icon_rgba(const char *path, uint8_t *rgba_out);

// Installs a (decrypted) CIA: a game, an update or DLC. progress(context, done, total) runs while
// copying. Returns Azahar's install status (0 success, 5 encrypted, others errors); *title_id gets
// the installed title's ID.
typedef void (*azh_progress_fn)(void *context, uint64_t done, uint64_t total);
int azh_install_cia(const char *path, azh_progress_fn progress, void *context, uint64_t *title_id);
// The file to run for an installed title (its main content), or NULL
char *azh_installed_title_path(uint64_t title_id);
// Every installed application (not updates or DLC): "path|titleId" lines
char *azh_installed_titles(void);
// Removes an installed title with its update and DLC
bool azh_uninstall_title(uint64_t title_id);

// Settings, by Azahar's own names (common/settings.h), as text: "layout_option" "2",
// "resolution_factor" "2", "use_cpu_jit" "1"... Take effect at the next boot, and right away for
// those that can change while a game runs (layout, swap_screen, volume, frame_limit...).
void azh_set_setting(const char *key, const char *value);

// Running a game. layer: a CAMetalLayer the core presents to. width and height in pixels.
// events(context, kind, a, b, text) is called from the emulation thread:
enum azh_event {
    AZH_EVENT_LOADING = 1, // a = stage (0 prepare, 1 preload, 2 decompile, 3 build, 4 done), b = percent
    AZH_EVENT_RUNNING = 2,
    AZH_EVENT_ERROR = 3, // text: what went wrong (the game keeps going when it can)
    AZH_EVENT_STOPPED = 4, // a = Azahar's result (0 normal exit); the last event of a session
    AZH_EVENT_STATE = 5,   // a save state: a = 0 saved / 1 loaded, b = slot; text NULL when it
                           // worked, otherwise what went wrong
    AZH_EVENT_KEYBOARD = 6, // the game wants text (naming, typing): text is the request as JSON, the
                            // answer goes back through azh_keyboard_result. Asked again (with an
                            // "error") when the game doesn't accept the answer. The game keeps running
};
typedef void (*azh_event_fn)(void *context, int kind, int a, int b, const char *text);
bool azh_boot(const char *path, void *layer, int width, int height, float scale, bool portrait,
              azh_event_fn events, void *context);
void azh_surface_changed(int width, int height, float scale, bool portrait);
void azh_set_paused(bool paused);
// Asks the game to end; AZH_EVENT_STOPPED follows
void azh_stop(void);
bool azh_running(void);
// Frames per second and speed (100 = full) over the last second
void azh_perf(double *fps, double *speed);
// Fast forward: on runs at percent (0 = as fast as the phone can), off returns to normal speed.
// Ends with the game.
void azh_set_fast_forward(bool on, int percent);
// Save states of the running game, slots 0...10. Done between two frames (also while paused);
// AZH_EVENT_STATE follows. false when no game runs or another one is still pending.
bool azh_save_state(int slot);
bool azh_load_state(int slot);
// The running game's save states: [{"slot":n,"time":unix seconds,"ok":bool}] (ok false: made by a
// different build, may not load). Free with azh_free
char *azh_save_states_json(void);

// The answer to AZH_EVENT_KEYBOARD: the text and which button was pressed (0 left, 1 middle, 2 right
// for three buttons; 0 Cancel, 1 Ok for two; 0 for one). Any thread; the emulation thread hands it to
// the game between two frames.
void azh_keyboard_result(const char *text, int button);

// Input. Buttons as a bit mask:
enum azh_button {
    AZH_A = 1 << 0,
    AZH_B = 1 << 1,
    AZH_X = 1 << 2,
    AZH_Y = 1 << 3,
    AZH_UP = 1 << 4,
    AZH_DOWN = 1 << 5,
    AZH_LEFT = 1 << 6,
    AZH_RIGHT = 1 << 7,
    AZH_L = 1 << 8,
    AZH_R = 1 << 9,
    AZH_START = 1 << 10,
    AZH_SELECT = 1 << 11,
    AZH_ZL = 1 << 12,
    AZH_ZR = 1 << 13,
    AZH_HOME = 1 << 14,
};
void azh_set_buttons(uint32_t mask);
// stick 0 circle pad, 1 C-stick; -1...1, up is +y
void azh_set_stick(int stick, float x, float y);
// The touch screen, in the layer's pixels: phase 0 down, 1 moved, 2 up
void azh_touch(int phase, float x, float y);
// Motion (gyroscope in degrees/s, accelerometer in g), from the phone's sensors
void azh_set_motion(float gx, float gy, float gz, float ax, float ay, float az);

#ifdef __cplusplus
}
#endif
