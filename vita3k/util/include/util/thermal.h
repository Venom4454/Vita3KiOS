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

#include <atomic>

#if defined(VITA3K_PLATFORM_IOS)
#include <pthread.h>
#include <sys/qos.h>
#endif

// How hard the emulator's threads ask the phone for speed. The iOS app sets both flags: "Keep the
// phone cool" (a setting, on by default) and whether iOS reports the phone as hot right now.
namespace thermal {

inline std::atomic<bool> &keep_cool() {
    static std::atomic<bool> value{ true };
    return value;
}

inline std::atomic<bool> &phone_is_hot() {
    static std::atomic<bool> value{ false };
    return value;
}

// iOS's thermal state: 0 nominal, 1 fair, 2 serious, 3 critical. "Fair" is the first sign of warmth:
// easing off there keeps the phone from ever reaching "serious"
inline std::atomic<int> &thermal_level() {
    static std::atomic<int> value{ 0 };
    return value;
}

// iOS Low Power Mode: the player asked for battery over speed, so the steps below apply even with
// "Keep the phone cool" off
inline std::atomic<bool> &low_power_mode() {
    static std::atomic<bool> value{ false };
    return value;
}

// One step down for the threads that follow it: the phone is hot and should be kept cool, or Low
// Power Mode is on
inline bool should_step_down() {
    return (keep_cool().load(std::memory_order_relaxed) && thermal_level().load(std::memory_order_relaxed) >= 1)
        || low_power_mode().load(std::memory_order_relaxed);
}

#if defined(VITA3K_PLATFORM_IOS)
// Game threads. User-interactive (the class of the UI thread) makes iOS raise the performance cores
// to their top clocks for every one of a game's 10 to 20 threads, most of which are background work
// (streaming, audio, loading): that is where the heat came from. User-initiated still runs them on the
// performance cores, without the race to the highest clock.
inline qos_class_t game_thread_qos() {
    return keep_cool().load(std::memory_order_relaxed) ? QOS_CLASS_USER_INITIATED : QOS_CLASS_USER_INTERACTIVE;
}

// The render loop (the renderer's heavy thread), called once per loop: full priority, one step down
// while the phone is hot and the player wants it kept cool, or in Low Power Mode. The vblank, display
// and GPU-wait threads stay at full priority: they barely work, and slowing them made frames uneven.
// `current` starts at 0 (user-interactive, set at thread start).
// If the phone still reaches "serious" with "Keep the phone cool", one more step (default class).
inline bool phone_still_heating() {
    return keep_cool().load(std::memory_order_relaxed) && thermal_level().load(std::memory_order_relaxed) >= 2;
}

inline void follow_render_qos(int &current) {
    int wanted = 0;
    if (phone_still_heating())
        wanted = 2;
    else if (should_step_down())
        wanted = 1;
    if (wanted == current)
        return;
    static constexpr qos_class_t classes[] = { QOS_CLASS_USER_INTERACTIVE, QOS_CLASS_USER_INITIATED, QOS_CLASS_DEFAULT };
    pthread_set_qos_class_self_np(classes[wanted], 0);
    current = wanted;
}

// Game threads again, followed while they run (every few hundred system calls): with "Keep the phone
// cool" (or in Low Power Mode) the game's own background threads, the ones it gave a
// lower priority than its default (streaming, loading, audio decoding helpers), move to utility class,
// where iOS is free to run them on the efficiency cores at low clocks. The game's main and render
// threads keep their class, so the frame rate holds while the heat drops. `current` starts at 0 (the
// class set at thread start).
inline void follow_game_qos(int &current, bool background_thread) {
    // Background threads used to drop to utility (efficiency cores) whenever "Keep the phone cool" was
    // on, even on a cold phone. Some games run their simulation there: Minecraft's world/server and
    // chunk threads run below the default priority, so chunks loaded seconds late and fall damage and
    // drowning were applied late. Now they keep the performance cores until the phone is actually hot:
    //   cool: the game threads' class; warm (fair) or Low Power Mode: default class (performance cores
    //   without the race to top clocks); serious (still heating with Keep cool): utility
    int wanted = 0;
    if (background_thread) {
        if (phone_still_heating() || low_power_mode().load(std::memory_order_relaxed))
            wanted = 2;
        else if (should_step_down())
            wanted = 1;
    } else if (phone_still_heating()) {
        wanted = 1;
    }
    if (wanted == current)
        return;
    const qos_class_t classes[] = { game_thread_qos(), QOS_CLASS_DEFAULT, QOS_CLASS_UTILITY };
    pthread_set_qos_class_self_np(classes[wanted], 0);
    current = wanted;
}

// Background workers (shader compilation), called once per job. They were started from the main
// thread and inherited its user-interactive class: four of them racing the performance cores to top
// clock whenever a game met new shaders. With "Keep the phone cool" they run user-initiated, and
// utility (efficiency cores welcome) while the phone is hot or in Low Power Mode. Shaders that are not
// ready yet are skipped for a frame or two (asynchronous compilation), so the game itself does not wait.
// `current` starts at -1 (not set yet).
inline void follow_worker_qos(int &current) {
    int wanted = 0;
    // While a shader compiles, whatever it draws is missing from the screen (objects "loading in
    // late"). On the efficiency cores that lasted several times longer, so with "Keep the phone cool"
    // they stay on the performance cores (without the race to top clocks) until the phone warms up,
    // and only then move to the efficiency cores. Compiles come in short bursts on new scenes.
    if (should_step_down())
        wanted = 2;
    else if (keep_cool().load(std::memory_order_relaxed))
        wanted = 1;
    if (wanted == current)
        return;
    static constexpr qos_class_t classes[] = { QOS_CLASS_USER_INTERACTIVE, QOS_CLASS_USER_INITIATED, QOS_CLASS_UTILITY };
    pthread_set_qos_class_self_np(classes[wanted], 0);
    current = wanted;
}
#endif

} // namespace thermal
