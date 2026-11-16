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

#include "audio/impl/sdl_audio.h"
#include "util/log.h"

#include <SDL3/SDL_audio.h>
#include <SDL3/SDL_hints.h>
#include <algorithm>
#include <chrono>

#define SDL_CHECK_EXT(condition, ret)                         \
    do {                                                      \
        if (!(condition)) {                                   \
            LOG_ERROR("SDL audio error: {}", SDL_GetError()); \
            return ret;                                       \
        }                                                     \
    } while (0)

#define SDL_CHECK(f_call) SDL_CHECK_EXT(f_call, {})
#define SDL_CHECK_VOID(f_call) SDL_CHECK_EXT(f_call, )
#define SDL_CHECK_NEG(f_call) SDL_CHECK_EXT((f_call) >= 0, {})

static int get_threshold_samples(const int device_buffer_samples) {
    return 4 * device_buffer_samples;
}

void SDLCALL SDLAudioAdapter::thread_wakeup_callback(void *userdata, SDL_AudioStream *stream, int additional_amount, int total_amount) {
    assert(userdata != nullptr);
    assert(stream != nullptr);
    SDLAudioOutPort *port = static_cast<SDLAudioOutPort *>(userdata);
    const int samples_available = port->adapter.get_rest_sample(*port);
    if (samples_available < get_threshold_samples(port->adapter.device_buffer_samples) || additional_amount > 0) {
        port->cond_var.notify_one();
    }
}

SDLAudioAdapter::SDLAudioAdapter(AudioState &audio_state)
    : AudioAdapter(audio_state) {}

SDLAudioAdapter::~SDLAudioAdapter() {
    if (device_id > 0) {
        SDL_CloseAudioDevice(device_id);
    }
}

bool SDLAudioAdapter::init() {
    // SDL3 default is 1024 sample frames for 48kHz audio, which is higher than cubeb.
    // Request smaller device buffer for lower latency callbacks.
    // 512 sample frames = 2048 bytes for stereo 16-bit, matching cubeb's callback size.
    SDL_SetHint(SDL_HINT_AUDIO_DEVICE_SAMPLE_FRAMES, "512");
    device_id = SDL_OpenAudioDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, nullptr);
    SDL_CHECK_EXT(device_id > 0, false);
    return true;
}

void SDLAudioAdapter::switch_state(const bool pause) {
    paused = pause;
    // Called on the main thread when the app leaves or returns. If the device is being opened or
    // closed right now (that waits on iOS), don't wait: the open applies paused when it finishes.
    std::unique_lock<std::mutex> lock(device_mutex, std::try_to_lock);
    if (!lock.owns_lock())
        return;
    if (device_id == 0)
        return; // suspended: applied when the device is reopened
    if (pause)
        SDL_CHECK_VOID(SDL_PauseAudioDevice(device_id));
    else
        SDL_CHECK_VOID(SDL_ResumeAudioDevice(device_id));
}

// iOS: a paused SDL device still keeps its audio queue running (playing silence), so the app could not
// hand the audio session back when it left the screen (other apps' videos stayed blocked). And when the
// session was handed back anyway, iOS stopped the queue behind SDL's back and SDL never restarted it:
// the game had no sound on return. Closing the device stops the queue cleanly (SDL also deactivates its
// session), and reopening it on return starts a fresh one; the game's streams are bound to it again.
void SDLAudioAdapter::suspend_output() {
    std::lock_guard<std::mutex> lock(device_mutex);
    if (device_id == 0)
        return;
    SDL_CloseAudioDevice(device_id); // also unbinds the streams, which keep their data
    device_id = 0;
    suspended = true;
    LOG_INFO("Audio output released (off screen)");
}

void SDLAudioAdapter::resume_output() {
    std::lock_guard<std::mutex> state_lock(state.mutex);
    std::lock_guard<std::mutex> lock(device_mutex);
    if (!suspended)
        return;
    suspended = false;
    device_id = SDL_OpenAudioDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, nullptr);
    if (device_id == 0) {
        LOG_ERROR("Audio output could not be reopened: {}", SDL_GetError());
        return;
    }
    SDL_GetAudioDeviceFormat(device_id, &dst_spec, &device_buffer_samples);
    for (auto &[_, port_ptr] : state.out_ports) {
        auto &port = static_cast<SDLAudioOutPort &>(*port_ptr);
        // Drop what queued up off screen, so the sound does not lag behind the game from now on
        SDL_ClearAudioStream(port.stream.get());
        if (!SDL_BindAudioStream(device_id, port.stream.get()))
            LOG_ERROR("Audio stream could not be bound again: {}", SDL_GetError());
    }
    if (paused.load())
        SDL_PauseAudioDevice(device_id);
    LOG_INFO("Audio output reopened ({} streams)", state.out_ports.size());
}

AudioOutPortPtr SDLAudioAdapter::open_port(int nb_channels, int freq, int nb_sample) {
    SDL_AudioSpec src_spec = {
        .format = SDL_AUDIO_S16LE,
        .channels = nb_channels,
        .freq = freq
    };
    std::unique_lock<std::mutex> device_lock(device_mutex);
    if (device_id != 0)
        SDL_CHECK(SDL_GetAudioDeviceFormat(device_id, &dst_spec, &device_buffer_samples));
    const AudioStreamPtr stream(SDL_CreateAudioStream(&src_spec, &dst_spec), SDL_DestroyAudioStream);
    SDL_CHECK(stream);
    // While suspended the stream is bound when the device is reopened
    if (device_id != 0)
        SDL_CHECK(SDL_BindAudioStream(device_id, stream.get()));
    device_lock.unlock();
    auto port = std::make_shared<SDLAudioOutPort>(stream, *this);
    SDL_CHECK(SDL_SetAudioStreamGetCallback(stream.get(), SDLAudioAdapter::thread_wakeup_callback, port.get()));
    port->channels = nb_channels;
    port->len_microseconds = (nb_sample * 1'000'000ULL) / freq;
    port->len_bytes = nb_sample * nb_channels * sizeof(int16_t);
    switch_state(false);
    return port;
}

void SDLAudioAdapter::audio_output(AudioOutPort &out_port, const void *buffer) {
    if (out_port.stopping)
        return;

    //  Put audio to the port's stream and see how much is left to play.
    SDLAudioOutPort &port = static_cast<SDLAudioOutPort &>(out_port);
    // If there's lots of audio left to play, stop this thread until the device has played it down.
    // The game's audio thread is paced by this wait (a Vita blocks here until its buffer is out), and
    // so is everything a game times by its audio: voices, subtitles, cutscenes. The device callback
    // wakes this thread on every refill, so the level is checked again after each wake: waiting for
    // one wake only let the game put one buffer per device refill, and on iOS (smaller, more frequent
    // refills than a game's buffer) games ran their dialogue up to 2x too fast (Dragon Ball Z: Battle of
    // Z, Dynasty Warriors 8) while the queued sound fell further and further behind.
    // At least 48 ms stays queued: with only four of the phone's small device buffers (~20-40 ms), a
    // game audio thread held up briefly by a busy CPU let the queue run dry, and the sound crackled
    // (Minecraft with every core busy). The pacing is the same, the cushion is bigger
    const int cushion = static_cast<int>(48'000ULL * std::max(dst_spec.freq, 1) / 1'000'000ULL);
    const int threshold = std::max({ get_threshold_samples(device_buffer_samples), cushion,
        static_cast<int>(static_cast<uint64_t>(out_port.len_microseconds) * std::max(dst_spec.freq, 1) / 1'000'000ULL) });
    // never longer than a few buffers in all: a device that stopped consuming (closed off screen, iOS
    // interrupting the audio) must not hang the game's audio thread
    const auto give_up = std::chrono::steady_clock::now() + std::chrono::microseconds(out_port.len_microseconds * 4 + 20'000);
    while (get_rest_sample(port) > threshold && std::chrono::steady_clock::now() < give_up) {
        std::unique_lock<std::mutex> lock(port.mutex);
        port.cond_var.wait_until(lock, std::min(give_up, std::chrono::steady_clock::now() + std::chrono::microseconds(out_port.len_microseconds)));
        if (out_port.stopping)
            return;
    }
    SDL_CHECK_VOID(SDL_PutAudioStreamData(port.stream.get(), buffer, out_port.len_bytes));
}

void SDLAudioAdapter::set_volume(AudioOutPort &out_port, float volume) {
    SDL_CHECK_VOID(SDL_SetAudioStreamGain(static_cast<SDLAudioOutPort &>(out_port).stream.get(), volume));
}

int SDLAudioAdapter::get_rest_sample(AudioOutPort &out_port) {
    auto &port = static_cast<SDLAudioOutPort &>(out_port);
    const int bytes_available = SDL_GetAudioStreamAvailable(port.stream.get());
    SDL_CHECK_NEG(bytes_available);
    // we have the number of bytes left, we can convert it back to the number of samples left
    return bytes_available / SDL_AUDIO_FRAMESIZE(dst_spec);
}

void SDLAudioAdapter::wake_all_ports() {
    for (auto &[_, port_ptr] : state.out_ports) {
        auto &port = static_cast<SDLAudioOutPort &>(*port_ptr);
        {
            std::lock_guard<std::mutex> lock(port.mutex);
        }
        port.cond_var.notify_all();
    }
}
