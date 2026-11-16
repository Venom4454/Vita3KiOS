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
#include <cstdint>

// How frames reach the screen, set by the platform layer and read by the screen renderer
// Guest sleeps (sceKernelDelayThread): how long games asked to sleep and how long they did, so a
// log shows whether short sleeps run long on the phone (timer coalescing slows worker loops)
namespace delay_stats {
inline std::atomic<uint64_t> &calls() {
    static std::atomic<uint64_t> v{ 0 };
    return v;
}
inline std::atomic<uint64_t> &asked_us() {
    static std::atomic<uint64_t> v{ 0 };
    return v;
}
inline std::atomic<uint64_t> &slept_us() {
    static std::atomic<uint64_t> v{ 0 };
    return v;
}
} // namespace delay_stats

namespace presentation {

// The game is shown on a TV or other display (iOS TV mode): every frame queued for the display adds
// latency on top of the stream to it, so at most one frame waits for the screen and a newer frame
// replaces rather than queues behind it
inline std::atomic<bool> &low_latency() {
    static std::atomic<bool> value{ false };
    return value;
}

// For the watchdog's log line: what the screen took, what it skipped, and how long the render thread
// waited on it (acquiring an image and presenting)
struct Counters {
    std::atomic<uint64_t> shown{ 0 };
    std::atomic<uint64_t> skipped{ 0 };
    std::atomic<uint64_t> wait_ns{ 0 };
};

inline Counters &counters() {
    static Counters value;
    return value;
}

} // namespace presentation
