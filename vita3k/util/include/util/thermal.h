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
#include <mach/mach.h>
#include <mach/thread_policy.h>
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

// Game threads ask for precise timers (latency tier 0): iOS otherwise lets their sleeps end late to
// save power (timer coalescing, more slack the lower the class). Logs showed guest sleeps running
// 15-35% long (368 us asked, 488 us slept), which slows every worker loop that paces itself with
// short sleeps. Setting a QoS class resets the tier, so it is set again after each change
inline void precise_timers_self() {
    thread_latency_qos_policy_data_t policy{ LATENCY_QOS_TIER_0 };
    thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_LATENCY_QOS_POLICY, reinterpret_cast<thread_policy_t>(&policy), THREAD_LATENCY_QOS_POLICY_COUNT);
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
    // Classes, fastest first: user-interactive (top clocks), user-initiated (performance cores without
    // the race to top clocks), default, utility (efficiency cores welcome).
    // Keep the phone cool used to hold every game thread one class down even on a cold phone, and its
    // background threads on utility: Minecraft's world and chunk threads (below default priority) fell
    // behind (chunks late, damage applied late). Now the steps follow the phone's actual heat:
    //   main threads:       cool: top; warm (fair): user-initiated; serious: default
    //   background threads: cool: user-initiated; warm: default; serious or Low Power Mode: utility
    // Without Keep the phone cool everything runs at the top class (Low Power Mode still steps down).
    static constexpr qos_class_t classes[] = { QOS_CLASS_USER_INTERACTIVE, QOS_CLASS_USER_INITIATED, QOS_CLASS_DEFAULT, QOS_CLASS_UTILITY };
    const bool cool_mode = keep_cool().load(std::memory_order_relaxed);
    const bool lpm = low_power_mode().load(std::memory_order_relaxed);
    const int heat = thermal_level().load(std::memory_order_relaxed); // 0 nominal, 1 fair, 2 serious, 3 critical
    int wanted = 0;
    if (cool_mode) {
        if (background_thread)
            wanted = (heat >= 2 || lpm) ? 3 : heat >= 1 ? 2
                                                        : 1;
        else
            wanted = heat >= 2 ? 2 : (heat >= 1 || lpm) ? 1
                                                        : 0;
    } else if (lpm) {
        wanted = background_thread ? 2 : 1;
    }
    // `current` is 0 at thread start (class game_thread_qos() set then), otherwise the class index + 1
    const int set_now = current > 0 ? current - 1 : (game_thread_qos() == QOS_CLASS_USER_INITIATED ? 1 : 0);
    if (wanted == set_now) {
        current = wanted + 1;
        return;
    }
    pthread_set_qos_class_self_np(classes[wanted], 0);
    precise_timers_self();
    current = wanted + 1;
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
