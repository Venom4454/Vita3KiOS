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

#include "game_extras.h"

#include "bridge/vita3k_bridge.h"
#include "ios_platform.h"

#include <config/state.h>
#include <display/state.h>
#include <emuenv/state.h>
#include <motion/functions.h>
#include <motion/state.h>
#include <renderer/display_layout.h>
#include <renderer/state.h>
#include <touch/functions.h>
#include <touch/state.h>
#include <util/fs.h>
#include <util/log.h>
#include <util/string_utils.h>

#include <fmt/chrono.h>
#include <fmt/format.h>
#include <stb_image_write.h>

#include <atomic>
#include <ctime>

// Implemented in Swift (ui/TouchControls.swift): a short message over the game
extern "C" void v3k_controls_toast(const char *message);

namespace {

std::atomic_bool screenshot_requested{ false };
std::atomic_bool rear_touch{ false };
std::atomic_bool rear_touch_applied{ false };
std::atomic_bool pstv_mode{ false };
int frames_since_rotation_check = 0;
int last_rotation = -2;

void take_screenshot(EmuEnvState &emuenv) {
    uint32_t width = 0, height = 0;
    std::vector<uint32_t> frame = emuenv.renderer->dump_frame(emuenv.display, width, height);
    if (frame.empty() || frame.size() != static_cast<size_t>(width) * height) {
        LOG_ERROR("Screenshot: the frame could not be read");
        v3k_controls_toast("Couldn't take a screenshot");
        return;
    }
    for (uint32_t &pixel : frame)
        pixel |= 0xFF000000;

    const std::string title = string_utils::remove_special_chars(emuenv.current_app_title);
    const fs::path folder = emuenv.shared_path / "screenshots" / title;
    std::error_code ec;
    fs::create_directories(folder, ec);
    const std::time_t now = std::time(nullptr);
    std::tm local{};
    localtime_r(&now, &local);
    const fs::path file = folder / fmt::format("{}_{:%Y-%m-%d-%H%M%S}.png", title, local);
    if (stbi_write_png(fs_utils::path_to_utf8(file).c_str(), width, height, 4, frame.data(), width * 4) != 1) {
        LOG_ERROR("Screenshot: could not write {}", file);
        v3k_controls_toast("Couldn't save the screenshot");
        return;
    }
    LOG_INFO("Screenshot saved to {}", file);
    // Also into Photos; the file stays in the Vita3K folder either way
    ios::save_image_to_photos(fs_utils::path_to_utf8(file));
}

} // namespace

extern "C" void v3k_request_screenshot(void) {
    screenshot_requested = true;
}

extern "C" void v3k_set_rear_touch(bool rear) {
    rear_touch = rear;
}

extern "C" bool v3k_rear_touch(void) {
    return rear_touch;
}

extern "C" bool v3k_pstv_mode(void) {
    return pstv_mode;
}

extern "C" void v3k_set_portrait_top(float pixels) {
    renderer::tall_window_top().store(pixels, std::memory_order_relaxed);
}

namespace ios::extras {

void session_started(EmuEnvState &emuenv) {
    screenshot_requested = false;
    rear_touch = false;
    rear_touch_applied = false;
    pstv_mode = emuenv.cfg.current_config.pstv_mode;
    set_rear_touchscreen(emuenv.touch, false);
    frames_since_rotation_check = 0;
    last_rotation = -2;
}

void frame(EmuEnvState &emuenv) {
    if (screenshot_requested.exchange(false))
        take_screenshot(emuenv);

    const bool rear = rear_touch;
    if (rear != rear_touch_applied) {
        rear_touch_applied = rear;
        set_rear_touchscreen(emuenv.touch, rear);
        LOG_INFO("Touch input now goes to the {} touchpad", rear ? "rear" : "front");
    }

    // Motion sensors report in the phone's portrait axes; the game runs in landscape, either way
    // round. Check the screen's orientation twice a second so tilting matches what the player sees.
    if (frames_since_rotation_check-- <= 0) {
        frames_since_rotation_check = 30;
        const int rotation = ios::interface_rotation();
        if (rotation >= 0 && rotation != last_rotation) {
            last_rotation = rotation;
            set_display_rotation(emuenv.motion, rotation);
            LOG_INFO("Motion sensors: screen rotation {}°", rotation * 90);
        }
    }
}

void session_ended(EmuEnvState &emuenv) {
    screenshot_requested = false;
    rear_touch = false;
    rear_touch_applied = false;
    pstv_mode = false;
    set_rear_touchscreen(emuenv.touch, false);
}

} // namespace ios::extras
