// Hinoki: Azahar's core behind a small C API (hinoki_azahar.h). Modelled on Azahar's Android
// frontend (src/android/app/src/main/jni): the same core calls, with a CAMetalLayer as the window.

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <tuple>
#include <vector>

#include <fmt/format.h>

#include "audio_core/sink_details.h"
#include "common/common_paths.h"
#include "common/file_util.h"
#include "common/logging/backend.h"
#include "common/logging/filter.h"
#include "common/logging/log.h"
#include "common/scm_rev.h"
#include "common/settings.h"
#include "common/string_util.h"
#include "common/vector_math.h"
#include "core/core.h"
#include "core/frontend/applets/default_applets.h"
#include "core/frontend/emu_window.h"
#include "core/frontend/input.h"
#include "core/hle/service/am/am.h"
#include "core/hle/service/fs/archive.h"
#include "core/loader/loader.h"
#include "core/loader/smdh.h"
#include "input_common/main.h"
#include "video_core/gpu.h"
#include "video_core/rasterizer_interface.h"
#include "video_core/renderer_base.h"

#include "hinoki_azahar.h"

// ---- What Hinoki lends the core (read by the patched oaknut, dynarmic setup and Vulkan loader) ----
extern "C" {
bool (*hinoki_jit_take)(std::size_t, void**, void**) = nullptr;
void (*hinoki_jit_return)(void*, void*, std::size_t) = nullptr;
std::size_t (*hinoki_jit_cache_size)(void) = nullptr;
void* hinoki_vk_get_instance_proc_addr = nullptr;
}

namespace {

azh_host g_host{};

char* dup(const std::string& text) {
    char* out = static_cast<char*>(std::malloc(text.size() + 1));
    std::memcpy(out, text.c_str(), text.size() + 1);
    return out;
}

std::string json_escape(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (const unsigned char c : in) {
        switch (c) {
        case '"':
            out += "\\\"";
            break;
        case '\\':
            out += "\\\\";
            break;
        case '\n':
            out += "\\n";
            break;
        case '\r':
        case '\t':
            out += ' ';
            break;
        default:
            if (c < 0x20)
                out += fmt::format("\\u{:04x}", c);
            else
                out += static_cast<char>(c);
        }
    }
    return out;
}

// ---- Input: state set by Hinoki, read by the core through "engine:hinoki" devices ----
std::atomic<uint32_t> g_buttons{0};
std::array<std::atomic<float>, 4> g_sticks{}; // circle x, y, c-stick x, y
std::array<std::atomic<float>, 6> g_motion{}; // gyro xyz, accel xyz

class HinokiButton final : public Input::ButtonDevice {
public:
    explicit HinokiButton(uint32_t bit_) : bit(bit_) {}
    bool GetStatus() const override {
        return (g_buttons.load(std::memory_order_relaxed) & bit) != 0;
    }

private:
    uint32_t bit;
};

class HinokiStick final : public Input::AnalogDevice {
public:
    explicit HinokiStick(int index_) : index(index_) {}
    std::tuple<float, float> GetStatus() const override {
        return {g_sticks[index * 2].load(std::memory_order_relaxed),
                g_sticks[index * 2 + 1].load(std::memory_order_relaxed)};
    }

private:
    int index;
};

class HinokiMotion final : public Input::MotionDevice {
public:
    std::tuple<Common::Vec3<float>, Common::Vec3<float>> GetStatus() const override {
        const Common::Vec3<float> gyro{g_motion[0].load(), g_motion[1].load(), g_motion[2].load()};
        const Common::Vec3<float> accel{g_motion[3].load(), g_motion[4].load(), g_motion[5].load()};
        return {accel, gyro};
    }
};

class ButtonFactory final : public Input::Factory<Input::ButtonDevice> {
public:
    std::unique_ptr<Input::ButtonDevice> Create(const Common::ParamPackage& params) override {
        return std::make_unique<HinokiButton>(static_cast<uint32_t>(params.Get("bit", 0)));
    }
};

class StickFactory final : public Input::Factory<Input::AnalogDevice> {
public:
    std::unique_ptr<Input::AnalogDevice> Create(const Common::ParamPackage& params) override {
        return std::make_unique<HinokiStick>(std::clamp(params.Get("stick", 0), 0, 1));
    }
};

class MotionFactory final : public Input::Factory<Input::MotionDevice> {
public:
    std::unique_ptr<Input::MotionDevice> Create(const Common::ParamPackage&) override {
        return std::make_unique<HinokiMotion>();
    }
};

void SetUpInputProfile() {
    using namespace Settings::NativeButton;
    const std::array<std::pair<Values, uint32_t>, 15> map{{
        {A, AZH_A},
        {B, AZH_B},
        {X, AZH_X},
        {Y, AZH_Y},
        {Up, AZH_UP},
        {Down, AZH_DOWN},
        {Left, AZH_LEFT},
        {Right, AZH_RIGHT},
        {L, AZH_L},
        {R, AZH_R},
        {Start, AZH_START},
        {Select, AZH_SELECT},
        {ZL, AZH_ZL},
        {ZR, AZH_ZR},
        {Home, AZH_HOME},
    }};
    auto& profile = Settings::values.current_input_profile;
    for (auto& button : profile.buttons)
        button.clear();
    for (const auto& [button, bit] : map)
        profile.buttons[button] = fmt::format("engine:hinoki,bit:{}", bit);
    profile.analogs[Settings::NativeAnalog::CirclePad] = "engine:hinoki,stick:0";
    profile.analogs[Settings::NativeAnalog::CStick] = "engine:hinoki,stick:1";
    profile.motion_device = "engine:hinoki";
    profile.touch_device = "engine:emu_window";
    profile.use_touch_from_button = false;
    profile.use_touchpad = false;
}

// ---- The window: a CAMetalLayer the Vulkan renderer presents to ----
class EmuWindow_Hinoki final : public Frontend::EmuWindow {
public:
    EmuWindow_Hinoki(void* layer, int width_, int height_, float scale, bool portrait_)
        : width(width_), height(height_), portrait(portrait_) {
        window_info.type = Frontend::WindowSystemType::MacOS;
        window_info.render_surface = layer;
        window_info.render_surface_scale = scale;
        UpdateCurrentFramebufferLayout(width, height, portrait);
    }

    void PollEvents() override {}

    std::unique_ptr<Frontend::GraphicsContext> CreateSharedContext() const override {
        return std::make_unique<Frontend::GraphicsContext>();
    }

    void Resize(int width_, int height_, float scale, bool portrait_) {
        width = width_;
        height = height_;
        portrait = portrait_;
        window_info.render_surface_scale = scale;
        UpdateCurrentFramebufferLayout(width, height, portrait);
    }

    bool Portrait() const {
        return portrait;
    }

private:
    int width;
    int height;
    bool portrait;
};

// ---- The running game ----
std::mutex g_session_mutex; // boot and stop
std::thread g_emu_thread;
std::unique_ptr<EmuWindow_Hinoki> g_window;
std::mutex g_window_mutex; // the window between the UI thread and the emulation thread
std::atomic<bool> g_stop{false};
std::atomic<bool> g_running{false};
std::atomic<bool> g_paused{false};
std::mutex g_pause_mutex;
std::condition_variable g_pause_cv;
std::atomic<double> g_fps{0.0};
std::atomic<double> g_speed{0.0};

const char* StatusText(Core::System::ResultStatus status, const std::string& details) {
    using Status = Core::System::ResultStatus;
    static thread_local std::string text;
    switch (status) {
    case Status::ErrorGetLoader:
        text = "This file is not a 3DS game Hinoki can open.";
        break;
    case Status::ErrorLoader_ErrorEncrypted:
        text = "This game is still encrypted. Import it again with your keys added (Settings › 3DS › "
               "Keys) so Hinoki can decrypt it.";
        break;
    case Status::ErrorLoader_ErrorInvalidFormat:
        text = "The file is damaged or not a supported format.";
        break;
    case Status::ErrorLoader_ErrorGbaTitle:
        text = "GBA Virtual Console titles are not supported.";
        break;
    case Status::ErrorSystemFiles:
        text = "This game needs 3DS system files that are missing: " + details;
        break;
    case Status::ErrorN3DSApplication:
        text = "This game needs a New 3DS: turn on New 3DS mode in Settings › 3DS.";
        break;
    case Status::ErrorCoreExceptionRaised:
        text = "The game crashed: " + details;
        break;
    case Status::ErrorShaderCacheCrash:
        text = "The shader cache of this game was being built when the app last closed. If the game "
               "closes again, clear the 3DS shader cache in Settings › 3DS.";
        break;
    default:
        text = details.empty() ? fmt::format("The game could not run (error {}).",
                                              static_cast<int>(status))
                               : details;
        break;
    }
    return text.c_str();
}

void EmulationThread(std::string path, azh_event_fn events, void* context) {
    auto& system = Core::System::GetInstance();
    const auto send = [&](int kind, int a, int b, const char* text) {
        if (events)
            events(context, kind, a, b, text);
    };

    FileUtil::SetCurrentRomPath(path);
    if (auto loader = Loader::GetLoader(path)) {
        u64 program_id = 0;
        loader->ReadProgramId(program_id);
        system.RegisterAppLoaderEarly(loader);
    }
    system.ApplySettings();
    Settings::LogSettings();

    Frontend::RegisterDefaultApplets(system);

    // (the window lives until this thread has ended: no lock, so the UI thread never waits on a boot)
    const Core::System::ResultStatus result = system.Load(*g_window, path);
    if (result != Core::System::ResultStatus::Success) {
        LOG_CRITICAL(Frontend, "Load failed: {}", static_cast<int>(result));
        send(AZH_EVENT_ERROR, static_cast<int>(result), 0,
             StatusText(result, system.GetStatusDetails()));
        system.Shutdown();
        g_running = false;
        send(AZH_EVENT_STOPPED, static_cast<int>(result), 0, nullptr);
        return;
    }

    u64 program_id = 0;
    system.GetAppLoader().ReadProgramId(program_id);
    system.GPU().ApplyPerProgramSettings(program_id);

    send(AZH_EVENT_LOADING, 0, 0, nullptr);
    system.GPU().Renderer().Rasterizer()->LoadDefaultDiskResources(
        g_stop, [&](VideoCore::LoadCallbackStage stage, std::size_t value, std::size_t total,
                    const std::string&) {
            const int percent = total ? static_cast<int>(value * 100 / total) : 0;
            send(AZH_EVENT_LOADING, static_cast<int>(stage), percent, nullptr);
        });
    send(AZH_EVENT_LOADING, static_cast<int>(VideoCore::LoadCallbackStage::Complete), 100, nullptr);

    system.RegisterCoreLoopThreadId();
    send(AZH_EVENT_RUNNING, 0, 0, nullptr);

    auto last_perf = std::chrono::steady_clock::now();
    Core::System::ResultStatus exit_status = Core::System::ResultStatus::Success;
    while (!g_stop) {
        if (g_paused) {
            const float volume = Settings::values.volume.GetValue();
            Settings::values.volume = 0.f;
            std::unique_lock lock{g_pause_mutex};
            g_pause_cv.wait(lock, [] { return !g_paused || g_stop; });
            Settings::values.volume = volume;
            continue;
        }
        const auto status = system.RunLoop();
        if (status == Core::System::ResultStatus::ShutdownRequested) {
            exit_status = status;
            break;
        }
        if (status != Core::System::ResultStatus::Success) {
            LOG_ERROR(Frontend, "RunLoop: {} ({})", static_cast<int>(status),
                      system.GetStatusDetails());
            send(AZH_EVENT_ERROR, static_cast<int>(status), 0,
                 StatusText(status, system.GetStatusDetails()));
            if (status == Core::System::ResultStatus::ErrorCoreExceptionRaised ||
                status == Core::System::ResultStatus::ErrorSystemFiles) {
                exit_status = status;
                break;
            }
        }
        const auto now = std::chrono::steady_clock::now();
        if (now - last_perf > std::chrono::seconds(1)) {
            const auto stats = system.GetAndResetPerfStats();
            g_fps = stats.game_fps;
            g_speed = stats.emulation_speed * 100.0;
            last_perf = now;
        }
    }

    system.Shutdown();
    g_running = false;
    send(AZH_EVENT_STOPPED, exit_status == Core::System::ResultStatus::ShutdownRequested
                                ? 0
                                : static_cast<int>(exit_status),
         0, nullptr);
}

bool ToBool(const std::string& value) {
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

} // namespace

namespace AudioCore {
std::unique_ptr<Sink> CreateHinokiSink(std::string_view);
}

extern "C" {

int azh_api_version(void) {
    return AZH_API_VERSION;
}

const char* azh_version(void) {
    return Common::g_build_fullname;
}

void azh_free(char* string) {
    std::free(string);
}

bool azh_init(const char* user_dir, const azh_host* host) {
    static bool initialised = false;
    if (host) {
        g_host = *host;
        hinoki_jit_take = g_host.jit_take;
        hinoki_jit_return = g_host.jit_return;
        hinoki_jit_cache_size = g_host.jit_cache_size;
        hinoki_vk_get_instance_proc_addr = g_host.vk_get_instance_proc_addr;
    }
    if (initialised)
        return true;
    initialised = true;

    FileUtil::SetUserPath(user_dir ? user_dir : "");
    Common::Log::Initialize();
    Common::Log::Start();
    static Common::Log::Filter filter{Common::Log::Level::Info};
    Common::Log::SetGlobalFilter(filter);
    LOG_INFO(Frontend, "Azahar {} for Hinoki, user folder {}", Common::g_build_fullname,
             user_dir ? user_dir : "(default)");

    // Phone defaults: Vulkan (MoltenVK), HLE applets (no 3DS system files needed), shaders built
    // in the background, a PICA shader interpreter (the shader JIT writes code where iOS doesn't
    // let it)
    Settings::values.graphics_api = Settings::GraphicsAPI::Vulkan;
    Settings::values.use_shader_jit = false;
    Settings::values.lle_applets = false;
    Settings::values.async_shader_compilation = true;
    Settings::values.use_disk_shader_cache = true;
    Settings::values.use_vsync = true;
    Settings::values.output_type = AudioCore::SinkType::Cubeb; // Hinoki's RemoteIO sink in that slot
    Settings::values.input_type = AudioCore::InputType::Static;
    Settings::values.layout_option = Settings::LayoutOption::LargeScreen;
    Settings::values.portrait_layout_option = Settings::PortraitLayoutOption::PortraitTopFullWidth;
    Settings::values.resolution_factor = 2;
    Settings::values.region_value = Settings::REGION_VALUE_AUTO_SELECT;

    InputCommon::Init();
    Input::RegisterFactory<Input::ButtonDevice>("hinoki", std::make_shared<ButtonFactory>());
    Input::RegisterFactory<Input::AnalogDevice>("hinoki", std::make_shared<StickFactory>());
    Input::RegisterFactory<Input::MotionDevice>("hinoki", std::make_shared<MotionFactory>());
    g_motion[4] = -1.f; // at rest: gravity straight down through the bottom screen
    SetUpInputProfile();
    return true;
}

char* azh_game_info_json(const char* path_c) {
    if (!path_c)
        return dup(R"({"ok":false})");
    const std::string path{path_c};
    auto loader = Loader::GetLoader(path);
    if (!loader)
        return dup(R"({"ok":false})");

    const auto type = loader->GetFileType();
    u64 program_id = 0;
    const auto id_result = loader->ReadProgramId(program_id);
    std::vector<u8> smdh_data;
    const auto icon_result = loader->ReadIcon(smdh_data, true);
    bool encrypted = id_result == Loader::ResultStatus::ErrorEncrypted ||
                     icon_result == Loader::ResultStatus::ErrorEncrypted;
    bool executable = false;
    if (loader->IsExecutable(executable) == Loader::ResultStatus::ErrorEncrypted)
        encrypted = true;

    std::string title, publisher, regions;
    if (smdh_data.size() >= sizeof(Loader::SMDH) && Loader::IsValidSMDH(smdh_data)) {
        Loader::SMDH smdh;
        std::memcpy(&smdh, smdh_data.data(), sizeof(smdh));
        const auto& entry = smdh.titles[static_cast<std::size_t>(Loader::SMDH::TitleLanguage::English)];
        title = Common::UTF16ToUTF8(std::u16string(entry.long_title.data()));
        if (title.empty()) {
            for (const auto& other : smdh.titles) {
                title = Common::UTF16ToUTF8(std::u16string(other.long_title.data()));
                if (!title.empty())
                    break;
            }
        }
        publisher = Common::UTF16ToUTF8(std::u16string(entry.publisher.data()));
        static constexpr std::array region_names{"JPN", "USA", "EUR", "AUS", "CHN", "KOR", "TWN"};
        for (const auto region : smdh.GetRegions()) {
            const auto index = static_cast<std::size_t>(region);
            if (index < region_names.size())
                regions += (regions.empty() ? "" : ",") + std::string(region_names[index]);
        }
    }
    if (title.empty())
        loader->ReadTitle(title, false);

    const u32 high = static_cast<u32>(program_id >> 32);
    std::string kind = "game";
    if (type == Loader::FileType::THREEDSX || type == Loader::FileType::ELF)
        kind = "homebrew";
    else if (high == 0x0004000E)
        kind = "update";
    else if (high == 0x0004008C)
        kind = "dlc";
    else if ((high & 0x10) != 0 && high != 0x00040000)
        kind = "system";

    return dup(fmt::format(
        R"({{"ok":true,"type":"{}","titleId":"{:016X}","title":"{}","publisher":"{}","encrypted":{},"executable":{},"kind":"{}","regions":"{}"}})",
        Loader::GetFileTypeString(type, loader->IsFileCompressed(), loader->IsFileBundle()),
        program_id, json_escape(title), json_escape(publisher), encrypted ? "true" : "false",
        executable ? "true" : "false", kind, regions));
}

bool azh_game_icon_rgba(const char* path, uint8_t* rgba_out) {
    if (!path || !rgba_out)
        return false;
    auto loader = Loader::GetLoader(path);
    if (!loader)
        return false;
    std::vector<u8> smdh_data;
    if (loader->ReadIcon(smdh_data, true) != Loader::ResultStatus::Success ||
        smdh_data.size() < sizeof(Loader::SMDH) || !Loader::IsValidSMDH(smdh_data))
        return false;
    Loader::SMDH smdh;
    std::memcpy(&smdh, smdh_data.data(), sizeof(smdh));
    const std::vector<u16> icon = smdh.GetIcon(true); // RGB565, 48x48
    for (std::size_t i = 0; i < icon.size() && i < 48 * 48; i++) {
        const u16 pixel = icon[i];
        const u8 r = static_cast<u8>((pixel >> 11) & 0x1F);
        const u8 g = static_cast<u8>((pixel >> 5) & 0x3F);
        const u8 b = static_cast<u8>(pixel & 0x1F);
        rgba_out[i * 4 + 0] = static_cast<u8>((r << 3) | (r >> 2));
        rgba_out[i * 4 + 1] = static_cast<u8>((g << 2) | (g >> 4));
        rgba_out[i * 4 + 2] = static_cast<u8>((b << 3) | (b >> 2));
        rgba_out[i * 4 + 3] = 0xFF;
    }
    return true;
}

int azh_install_cia(const char* path, azh_progress_fn progress, void* context, uint64_t* title_id) {
    if (!path)
        return static_cast<int>(Service::AM::InstallStatus::ErrorFileNotFound);
    if (title_id) {
        *title_id = 0;
        if (auto infos = Service::AM::GetCIAInfos(path); infos.Succeeded())
            *title_id = infos.Unwrap().first.tid;
    }
    const auto status = Service::AM::InstallCIA(
        path, [progress, context](std::size_t done, std::size_t total) {
            if (progress)
                progress(context, done, total);
        });
    LOG_INFO(Frontend, "Installed {}: status {}", path, static_cast<int>(status));
    return static_cast<int>(status);
}

char* azh_installed_title_path(uint64_t title_id) {
    const auto media = Service::AM::GetTitleMediaType(title_id);
    const std::string path = Service::AM::GetTitleContentPath(media, title_id);
    if (path.empty() || !FileUtil::Exists(path))
        return nullptr;
    return dup(path);
}

char* azh_installed_titles(void) {
    std::string out;
    const std::string root = FileUtil::GetUserPath(FileUtil::UserPath::SDMCDir) +
                             "Nintendo 3DS/00000000000000000000000000000000/"
                             "00000000000000000000000000000000/title/00040000/";
    FileUtil::FSTEntry entries;
    FileUtil::ScanDirectoryTree(root, entries, 0);
    for (const auto& child : entries.children) {
        if (!child.isDirectory || child.virtualName.size() != 8)
            continue;
        const u64 low = std::strtoull(child.virtualName.c_str(), nullptr, 16);
        const u64 tid = (u64{0x00040000} << 32) | low;
        const std::string path = Service::AM::GetTitleContentPath(Service::FS::MediaType::SDMC, tid);
        if (!path.empty() && FileUtil::Exists(path))
            out += fmt::format("{}|{:016X}\n", path, tid);
    }
    return dup(out);
}

bool azh_uninstall_title(uint64_t title_id) {
    const auto media = Service::AM::GetTitleMediaType(title_id);
    bool ok = Service::AM::UninstallProgram(media, title_id).IsSuccess();
    // its update and DLC go with it
    const u64 low = title_id & 0xFFFFFFFF;
    for (const u64 high : {u64{0x0004000E}, u64{0x0004008C}}) {
        const u64 extra = (high << 32) | low;
        const std::string folder = Service::AM::GetTitlePath(Service::FS::MediaType::SDMC, extra);
        if (FileUtil::Exists(folder))
            Service::AM::UninstallProgram(Service::FS::MediaType::SDMC, extra);
    }
    return ok;
}

void azh_set_setting(const char* key_c, const char* value_c) {
    if (!key_c || !value_c)
        return;
    const std::string key{key_c}, value{value_c};
    auto& v = Settings::values;
    const int number = std::atoi(value.c_str());
    const double real = std::atof(value.c_str());
    bool layout_changed = false;

    if (key == "layout_option") {
        v.layout_option = static_cast<Settings::LayoutOption>(number);
        layout_changed = true;
    } else if (key == "portrait_layout_option") {
        v.portrait_layout_option = static_cast<Settings::PortraitLayoutOption>(number);
        layout_changed = true;
    } else if (key == "swap_screen") {
        v.swap_screen = ToBool(value);
        layout_changed = true;
    } else if (key == "large_screen_proportion") {
        v.large_screen_proportion = static_cast<float>(real);
        layout_changed = true;
    } else if (key == "resolution_factor") {
        v.resolution_factor = static_cast<u32>(std::clamp(number, 1, 10));
    } else if (key == "use_cpu_jit") {
        v.use_cpu_jit = ToBool(value);
    } else if (key == "cpu_clock_percentage") {
        v.cpu_clock_percentage = std::clamp(number, 25, 400);
    } else if (key == "is_new_3ds") {
        v.is_new_3ds = ToBool(value);
    } else if (key == "region_value") {
        v.region_value = number;
    } else if (key == "frame_limit") {
        v.frame_limit = real;
    } else if (key == "async_shader_compilation") {
        v.async_shader_compilation = ToBool(value);
    } else if (key == "use_disk_shader_cache") {
        v.use_disk_shader_cache = ToBool(value);
    } else if (key == "texture_filter") {
        v.texture_filter = static_cast<Settings::TextureFilter>(number);
    } else if (key == "filter_mode") {
        v.filter_mode = ToBool(value);
    } else if (key == "volume") {
        v.volume = static_cast<float>(std::clamp(real, 0.0, 1.0));
    } else if (key == "use_vsync") {
        v.use_vsync = ToBool(value);
    } else if (key == "shaders_accurate_mul") {
        v.shaders_accurate_mul = ToBool(value);
    } else if (key == "use_hw_shader") {
        v.use_hw_shader = ToBool(value);
    } else if (key == "custom_textures") {
        v.custom_textures = ToBool(value);
    } else if (key == "preload_textures") {
        v.preload_textures = ToBool(value);
    } else if (key == "enable_audio_stretching") {
        v.enable_audio_stretching = ToBool(value);
    } else if (key == "lle_applets") {
        v.lle_applets = ToBool(value);
    } else if (key == "render_3d") {
        v.render_3d = static_cast<Settings::StereoRenderOption>(number);
    } else if (key == "factor_3d") {
        v.factor_3d = static_cast<u32>(std::clamp(number, 0, 100));
    } else if (key == "delay_game_render_thread_us") {
        v.delay_game_render_thread_us = static_cast<u16>(std::clamp(number, 0, 16000));
    } else {
        LOG_WARNING(Frontend, "Unknown setting {}", key);
        return;
    }

    auto& system = Core::System::GetInstance();
    if (g_running && system.IsPoweredOn()) {
        system.ApplySettings();
        if (layout_changed) {
            std::scoped_lock lock{g_window_mutex};
            if (g_window)
                system.GPU().Renderer().UpdateCurrentFramebufferLayout(g_window->Portrait());
        }
    }
}

bool azh_boot(const char* path, void* layer, int width, int height, float scale, bool portrait,
              azh_event_fn events, void* context) {
    std::scoped_lock lock{g_session_mutex};
    if (!path || !layer || g_running)
        return false;
    if (g_emu_thread.joinable())
        g_emu_thread.join();

    g_stop = false;
    g_paused = false;
    g_running = true;
    g_buttons = 0;
    for (auto& value : g_sticks)
        value = 0.f;
    {
        std::scoped_lock window_lock{g_window_mutex};
        g_window = std::make_unique<EmuWindow_Hinoki>(layer, width, height, scale, portrait);
    }
    g_emu_thread = std::thread(EmulationThread, std::string(path), events, context);
    return true;
}

void azh_surface_changed(int width, int height, float scale, bool portrait) {
    std::scoped_lock lock{g_window_mutex};
    if (!g_window)
        return;
    g_window->Resize(width, height, scale, portrait);
    auto& system = Core::System::GetInstance();
    if (g_running && system.IsPoweredOn())
        system.GPU().Renderer().UpdateCurrentFramebufferLayout(portrait);
}

void azh_set_paused(bool paused) {
    {
        std::scoped_lock lock{g_pause_mutex};
        g_paused = paused;
    }
    g_pause_cv.notify_all();
}

void azh_stop(void) {
    {
        std::scoped_lock lock{g_pause_mutex};
        g_stop = true;
        g_paused = false;
    }
    g_pause_cv.notify_all();
    // The thread ends by itself (AZH_EVENT_STOPPED); it is joined at the next boot
    std::thread([] {
        std::scoped_lock lock{g_session_mutex};
        if (g_emu_thread.joinable())
            g_emu_thread.join();
        std::scoped_lock window_lock{g_window_mutex};
        g_window.reset();
    }).detach();
}

bool azh_running(void) {
    return g_running;
}

void azh_perf(double* fps, double* speed) {
    if (fps)
        *fps = g_fps;
    if (speed)
        *speed = g_speed;
}

void azh_set_buttons(uint32_t mask) {
    g_buttons.store(mask, std::memory_order_relaxed);
}

void azh_set_stick(int stick, float x, float y) {
    if (stick < 0 || stick > 1)
        return;
    g_sticks[stick * 2] = std::clamp(x, -1.f, 1.f);
    g_sticks[stick * 2 + 1] = std::clamp(y, -1.f, 1.f);
}

void azh_touch(int phase, float x, float y) {
    std::scoped_lock lock{g_window_mutex};
    if (!g_window)
        return;
    const unsigned px = static_cast<unsigned>(std::max(0.f, x));
    const unsigned py = static_cast<unsigned>(std::max(0.f, y));
    switch (phase) {
    case 0:
        g_window->TouchPressed(px, py);
        break;
    case 1:
        g_window->TouchMoved(px, py);
        break;
    default:
        g_window->TouchReleased();
        break;
    }
}

void azh_set_motion(float gx, float gy, float gz, float ax, float ay, float az) {
    g_motion[0] = gx;
    g_motion[1] = gy;
    g_motion[2] = gz;
    g_motion[3] = ax;
    g_motion[4] = ay;
    g_motion[5] = az;
}

} // extern "C"
