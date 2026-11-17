// Hinoki: 3DS audio out through iOS's RemoteIO audio unit. It takes the core's stereo 16-bit samples
// at the 3DS rate and converts them to the phone's own rate itself. Hinoki has already set up the
// app's audio session (playback, mixing with other apps as the player chose).

#include <algorithm>
#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

#include <AudioToolbox/AudioToolbox.h>

#include "audio_core/audio_types.h"
#include "audio_core/sink.h"
#include "common/logging/log.h"

namespace AudioCore {

namespace {

class HinokiSink final : public Sink {
public:
    HinokiSink() {
        AudioComponentDescription description{};
        description.componentType = kAudioUnitType_Output;
        description.componentSubType = kAudioUnitSubType_RemoteIO;
        description.componentManufacturer = kAudioUnitManufacturer_Apple;
        AudioComponent component = AudioComponentFindNext(nullptr, &description);
        if (!component || AudioComponentInstanceNew(component, &unit) != noErr) {
            LOG_ERROR(Audio_Sink, "No audio output unit");
            unit = nullptr;
            return;
        }

        AudioStreamBasicDescription format{};
        format.mSampleRate = native_sample_rate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        format.mChannelsPerFrame = 2;
        format.mBitsPerChannel = 16;
        format.mBytesPerFrame = 4;
        format.mFramesPerPacket = 1;
        format.mBytesPerPacket = 4;
        OSStatus status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                               kAudioUnitScope_Input, 0, &format, sizeof(format));

        AURenderCallbackStruct render{};
        render.inputProc = &HinokiSink::Render;
        render.inputProcRefCon = this;
        if (status == noErr)
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                          kAudioUnitScope_Input, 0, &render, sizeof(render));
        if (status == noErr)
            status = AudioUnitInitialize(unit);
        if (status == noErr)
            status = AudioOutputUnitStart(unit);
        if (status != noErr) {
            LOG_ERROR(Audio_Sink, "Audio output could not start ({})", static_cast<int>(status));
            AudioComponentInstanceDispose(unit);
            unit = nullptr;
            return;
        }
        LOG_INFO(Audio_Sink, "Audio out: RemoteIO at {} Hz", native_sample_rate);
    }

    ~HinokiSink() override {
        if (unit) {
            AudioOutputUnitStop(unit);
            AudioUnitUninitialize(unit);
            AudioComponentInstanceDispose(unit);
        }
    }

    unsigned int GetNativeSampleRate() const override {
        return native_sample_rate;
    }

    void SetCallback(std::function<void(s16*, std::size_t)> cb) override {
        std::scoped_lock lock{callback_mutex};
        callback = std::move(cb);
    }

private:
    static OSStatus Render(void* ref, AudioUnitRenderActionFlags* flags, const AudioTimeStamp*,
                           UInt32, UInt32 frames, AudioBufferList* buffers) {
        auto* self = static_cast<HinokiSink*>(ref);
        auto& buffer = buffers->mBuffers[0];
        auto* samples = static_cast<s16*>(buffer.mData);
        const std::size_t count = std::min<std::size_t>(frames, buffer.mDataByteSize / 4);
        std::unique_lock lock{self->callback_mutex, std::try_to_lock};
        if (lock.owns_lock() && self->callback) {
            self->callback(samples, count);
        } else {
            std::fill(samples, samples + count * 2, s16{0});
            *flags |= kAudioUnitRenderAction_OutputIsSilence;
        }
        return noErr;
    }

    AudioComponentInstance unit = nullptr;
    std::mutex callback_mutex;
    std::function<void(s16*, std::size_t)> callback;
};

} // namespace

std::unique_ptr<Sink> CreateHinokiSink(std::string_view) {
    return std::make_unique<HinokiSink>();
}

std::vector<std::string> ListHinokiSinkDevices() {
    return {"Hinoki"};
}

} // namespace AudioCore
