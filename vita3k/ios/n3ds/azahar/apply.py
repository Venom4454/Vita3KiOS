#!/usr/bin/env python3
"""Prepares an Azahar checkout for Hinoki's 3DS core (vita3k/ios/n3ds/azahar).

Usage: apply.py <azahar checkout>

1. Copies the Hinoki frontend (hinoki/) into src/hinoki and adds it to the build.
2. Small source edits, each checked (the build stops if Azahar changed under one):
   - oaknut: JIT code memory from Hinoki's pool on iOS (a read-execute view plus a writable alias of
     the same pages: iOS 26 never lets one mapping be both), the scheme Hinoki's own JIT uses
     (vita3k/ios/patches/0001-oaknut-ios-rwx-jit.patch, from Tsubomi by 125hz)
   - dynarmic: writes through the writable alias; spin lock in plain C (it compiled its own code)
   - ARM_Dynarmic: code cache sizes the pool holds
   - Vulkan: Hinoki's MoltenVK (one Vulkan driver per app)
   - audio: Hinoki's RemoteIO output in the sink list; no sped-up sound after a stall
   - Vulkan: a smaller texture upload ring (phone memory)
Every edit is idempotent: running it twice changes nothing more.
"""
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1]).resolve()
here = pathlib.Path(__file__).resolve().parent
MARK = "HINOKI"


def edit(rel, old, new, count=1):
    path = root / rel
    text = path.read_text()
    if MARK in text and new in text:
        print(f"  {rel}: already done")
        return
    found = text.count(old)
    if found != count:
        sys.exit(f"apply.py: {rel}: expected {count} match(es), found {found}:\n{old}")
    path.write_text(text.replace(old, new))
    print(f"  {rel}: done")


# ---- 1. the frontend ----
dest = root / "src" / "hinoki"
if dest.exists():
    shutil.rmtree(dest)
shutil.copytree(here / "hinoki", dest)
edit("src/CMakeLists.txt", "add_subdirectory(input_common)\n",
     "add_subdirectory(input_common)\n# HINOKI: Hinoki's 3DS core (vita3k/ios/n3ds/azahar)\nadd_subdirectory(hinoki)\n")

# ---- 2a. oaknut code memory ----
OAKNUT_HOST = r'''
#if defined(__APPLE__) && TARGET_OS_IPHONE
// HINOKI: code memory lent by Hinoki (iOS 26: regions StikDebug prepared, read-execute plus a
// writable alias). Set by azh_init; null outside Hinoki.
extern "C" {
extern bool (*hinoki_jit_take)(std::size_t, void**, void**) __attribute__((weak));
extern void (*hinoki_jit_return)(void*, void*, std::size_t) __attribute__((weak));
}
#endif

class CodeBlock {'''

for code_block in sorted(root.glob("externals/**/oaknut/include/oaknut/code_block.hpp")):
    rel = code_block.relative_to(root)
    edit(rel, "\nclass CodeBlock {", OAKNUT_HOST)
    edit(rel, """#    if TARGET_OS_IPHONE
        m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
#    else""", """#    if TARGET_OS_IPHONE
        // HINOKI: Hinoki's pool first; otherwise one mapping that flips between writable and
        // executable (the debugger JIT of iOS 17/18)
        void* rx = nullptr;
        void* rw = nullptr;
        if (&hinoki_jit_take != nullptr && hinoki_jit_take != nullptr && hinoki_jit_take(size, &rx, &rw)) {
            m_memory = static_cast<std::uint32_t*>(rx);
            m_write_memory = static_cast<std::uint32_t*>(rw);
            m_lent = true;
        } else {
            m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
            if (m_memory == MAP_FAILED)
                throw std::bad_alloc{};
            m_write_memory = m_memory;
        }
#    else""")
    edit(rel, """#if defined(_WIN32)
        VirtualFree((void*)m_memory, 0, MEM_RELEASE);
#else
        munmap(m_memory, m_size);""", """#if defined(_WIN32)
        VirtualFree((void*)m_memory, 0, MEM_RELEASE);
#else
#    if defined(__APPLE__) && TARGET_OS_IPHONE
        // HINOKI: lent memory goes back to Hinoki's pool
        if (m_lent) {
            if (&hinoki_jit_return != nullptr && hinoki_jit_return != nullptr)
                hinoki_jit_return(m_memory, m_write_memory, m_size);
            m_memory = nullptr;
            return;
        }
#    endif
        munmap(m_memory, m_size);""")
    edit(rel, """    std::uint32_t* ptr() const
    {
        return m_memory;
    }
""", """    std::uint32_t* ptr() const
    {
        return m_memory;
    }

    // HINOKI: where to execute and where to write (the same, except with Hinoki's iOS pool)
    std::uint32_t* xptr() const
    {
        return m_memory;
    }

    std::uint32_t* wptr() const
    {
#if defined(__APPLE__) && TARGET_OS_IPHONE
        return m_write_memory;
#else
        return m_memory;
#endif
    }
""")
    edit(rel, """#if defined(__APPLE__) && !TARGET_OS_IPHONE
        pthread_jit_write_protect_np(1);
#elif""", """#if defined(__APPLE__) && !TARGET_OS_IPHONE
        pthread_jit_write_protect_np(1);
#elif defined(__APPLE__) && TARGET_OS_IPHONE
        if (m_write_memory == m_memory)  // HINOKI
            mprotect(m_memory, m_size, PROT_READ | PROT_EXEC);
#elif""")
    edit(rel, """#if defined(__APPLE__) && !TARGET_OS_IPHONE
        pthread_jit_write_protect_np(0);
#elif""", """#if defined(__APPLE__) && !TARGET_OS_IPHONE
        pthread_jit_write_protect_np(0);
#elif defined(__APPLE__) && TARGET_OS_IPHONE
        if (m_write_memory == m_memory)  // HINOKI
            mprotect(m_memory, m_size, PROT_READ | PROT_WRITE);
#elif""")
    edit(rel, """protected:
    std::uint32_t* m_memory;
""", """protected:
    std::uint32_t* m_memory;
#if defined(__APPLE__) && TARGET_OS_IPHONE
    std::uint32_t* m_write_memory = nullptr;  // HINOKI
    bool m_lent = false;
#endif
""")

# ---- 2b. dynarmic: emit through the writable alias ----
edit("externals/dynarmic/src/dynarmic/backend/arm64/address_space.cpp",
     "        , code(mem.ptr(), mem.ptr())",
     "        , code(mem.wptr(), mem.xptr())  // HINOKI")
edit("externals/dynarmic/src/dynarmic/backend/arm64/address_space.cpp",
     "        CodeGenerator c{mem.ptr(), mem.ptr()};",
     "        CodeGenerator c{mem.wptr(), mem.xptr()};  // HINOKI", count=2)

SPIN = "externals/dynarmic/src/dynarmic/common/spin_lock_arm64.cpp"
edit(SPIN, "#include <mutex>\n", "#include <mutex>\n#if defined(__APPLE__)\n#    include <TargetConditionals.h>\n#endif\n")
edit(SPIN, "\nnamespace {\n\nstruct SpinLockImpl {",
     "\n// HINOKI: on iOS the lock is plain C (it used to compile itself into JIT memory)\n#if !defined(__APPLE__) || !TARGET_OS_IPHONE\nnamespace {\n\nstruct SpinLockImpl {")
edit(SPIN, """void SpinLock::Lock() {
    std::call_once(flag, &SpinLockImpl::Initialize, impl);
    impl.lock(&storage);
}

void SpinLock::Unlock() {
    std::call_once(flag, &SpinLockImpl::Initialize, impl);
    impl.unlock(&storage);
}""", """#endif

void SpinLock::Lock() {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    while (__atomic_exchange_n(&storage, 1, __ATOMIC_ACQUIRE) != 0) {
        while (__atomic_load_n(&storage, __ATOMIC_RELAXED) != 0) {
            __asm__ volatile("yield");
        }
    }
#else
    std::call_once(flag, &SpinLockImpl::Initialize, impl);
    impl.lock(&storage);
#endif
}

void SpinLock::Unlock() {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    __atomic_store_n(&storage, 0, __ATOMIC_RELEASE);
#else
    std::call_once(flag, &SpinLockImpl::Initialize, impl);
    impl.unlock(&storage);
#endif
}""")

# ---- 2c. code cache sizes from Hinoki's pool ----
ARM = "src/core/arm/dynarmic/arm_dynarmic.cpp"
edit(ARM, "\nnamespace Core {\n", """
// HINOKI: the code cache size Hinoki's JIT pool holds next (set by azh_init, null elsewhere)
extern "C" std::size_t (*hinoki_jit_cache_size)(void) __attribute__((weak));

namespace Core {
""")
edit(ARM, "    config.define_unpredictable_behaviour = true;\n",
     """    config.define_unpredictable_behaviour = true;
    if (&hinoki_jit_cache_size != nullptr && hinoki_jit_cache_size != nullptr) {
        if (const std::size_t size = hinoki_jit_cache_size(); size != 0)
            config.code_cache_size = size;  // HINOKI
    }
""")

# ---- 2d. Vulkan through Hinoki's MoltenVK ----
VKP = "src/video_core/renderer_vulkan/vk_platform.cpp"
edit(VKP, "\nnamespace Vulkan {\n", """
// HINOKI: vkGetInstanceProcAddr of the MoltenVK in Hinoki (set by azh_init, null elsewhere)
extern "C" void* hinoki_vk_get_instance_proc_addr __attribute__((weak));

namespace Vulkan {
""")
edit(VKP, """    if (!library.IsLoaded()) {
        throw std::runtime_error("Failed to load Vulkan driver library");
    }

    const auto vkGetInstanceProcAddr =
        library.GetSymbol<PFN_vkGetInstanceProcAddr>("vkGetInstanceProcAddr");
    if (!vkGetInstanceProcAddr) {""", """    PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr = nullptr;
    if (&hinoki_vk_get_instance_proc_addr != nullptr && hinoki_vk_get_instance_proc_addr) {
        vkGetInstanceProcAddr =  // HINOKI
            reinterpret_cast<PFN_vkGetInstanceProcAddr>(hinoki_vk_get_instance_proc_addr);
    } else {
        if (!library.IsLoaded()) {
            throw std::runtime_error("Failed to load Vulkan driver library");
        }
        vkGetInstanceProcAddr =
            library.GetSymbol<PFN_vkGetInstanceProcAddr>("vkGetInstanceProcAddr");
    }
    if (!vkGetInstanceProcAddr) {""")

# ---- 2e. audio out ----
SINK = "src/audio_core/sink_details.cpp"
edit(SINK, "namespace AudioCore {\nnamespace {\n", """namespace AudioCore {
#ifdef HAVE_HINOKI_SINK
// HINOKI: iOS RemoteIO output (src/hinoki/hinoki_sink.cpp), listed in the Cubeb slot (no cubeb on iOS)
std::unique_ptr<Sink> CreateHinokiSink(std::string_view device_id);
std::vector<std::string> ListHinokiSinkDevices();
#endif
namespace {
""")
edit(SINK, "constexpr std::array sink_details = {\n", """constexpr std::array sink_details = {
#ifdef HAVE_HINOKI_SINK
    SinkDetails{SinkType::Cubeb, "Hinoki", &CreateHinokiSink, &ListHinokiSinkDevices},
#endif
""")

# ---- 2f. common/apple_utils.mm is macOS only (Cocoa, NSScreen): iOS takes the refresh rate from UIScreen ----
edit("src/common/apple_utils.mm", """#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

namespace AppleUtils {

float GetRefreshRate() {""", """#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h> // HINOKI
#else
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#endif
#import <Foundation/Foundation.h>

namespace AppleUtils {

#if TARGET_OS_IPHONE
float GetRefreshRate() {
    const NSInteger fps = [UIScreen mainScreen].maximumFramesPerSecond;
    return fps > 0 ? static_cast<float>(fps) : 60.f;
}
#else
float GetRefreshRate() {""")
edit("src/common/apple_utils.mm", """    return 60; // Something went wrong, so just return a generic value
}
""", """    return 60; // Something went wrong, so just return a generic value
}
#endif // HINOKI
""")

# ---- 2g. audio stretching: no sped-up sound after a stall ----
# A stall (a game loading, a level starting) left a backlog that the stretcher then played back fast
# until it drained: the music and effects raced for a second each time something new loaded. Hold the
# tempo through a stall, never play faster than the emulation runs, and drop a backlog past ~0.4 s.
TS = "src/audio_core/time_stretch.cpp"
edit(TS, '#include "common/logging/log.h"\n', '#include "common/logging/log.h"\n#include "common/settings.h" // HINOKI\n')
edit(TS, """    const double backlog_fullness = sound_touch->numSamples() / max_backlog;
    if (backlog_fullness > 4.0) {""", """    double backlog_fullness = sound_touch->numSamples() / max_backlog;
    // HINOKI: a backlog this long would be heard sped up: skip it once instead
    if (backlog_fullness > 1.5) {
        sound_touch->receiveSamples(
            static_cast<unsigned int>(sound_touch->numSamples() - max_backlog * 0.5));
        backlog_fullness = sound_touch->numSamples() / max_backlog;
    }
    // HINOKI: no samples for a while is a stall (loading), not slow emulation: keep the tempo
    static thread_local double hinoki_starved = 0.0;
    hinoki_starved = num_in == 0 ? hinoki_starved + time_delta : 0.0;
    const bool hinoki_stalled = hinoki_starved > 0.1;
    if (backlog_fullness > 4.0) {""")
edit(TS, """    stretch_ratio += lpf_gain * (current_ratio - stretch_ratio);

    // Place a lower limit of 5% speed. When a game boots up, there will be
    // many silence samples. These do not need to be timestretched.
    stretch_ratio = std::max(stretch_ratio, 0.05);""", """    if (!hinoki_stalled) { // HINOKI
        stretch_ratio += lpf_gain * (current_ratio - stretch_ratio);
    }

    // Place a lower limit of 5% speed. When a game boots up, there will be
    // many silence samples. These do not need to be timestretched.
    stretch_ratio = std::max(stretch_ratio, 0.05);
    // HINOKI: never faster than the emulation may run (full speed, or the fast forward speed)
    const double hinoki_limit = Settings::GetFrameLimit();
    stretch_ratio = std::min(stretch_ratio,
                             hinoki_limit <= 0 ? 4.0 : std::max(1.02, hinoki_limit / 100.0));""")

# ---- 2h. memory: the texture upload ring is shared memory on a phone ----
# 512 MiB of host-visible memory counts against the app's limit on iOS (unified memory); 128 MiB
# still holds the largest custom texture with its mipmaps
edit("src/video_core/renderer_vulkan/vk_texture_runtime.cpp",
     "constexpr u64 UPLOAD_BUFFER_SIZE = 512_MiB;",
     "constexpr u64 UPLOAD_BUFFER_SIZE = 128_MiB; // HINOKI: 512 MiB on desktop")

# ---- 2i. performance cores: iOS places threads by their quality of service ----
# Azahar's threads ran at the default QoS, so iOS was free to run the Vulkan worker (it records and
# submits every frame's GPU work) and the presentation thread on the efficiency cores. Named threads
# that pace the game get user-interactive (performance cores); shader builders user-initiated.
TH = "src/common/thread.cpp"
edit(TH, """#if !defined(_WIN32) || defined(_MSC_VER)
void SetCurrentThreadName(const char* name) {
#ifdef __APPLE__
    pthread_setname_np(name);""", """#if !defined(_WIN32) || defined(_MSC_VER)
void SetCurrentThreadName(const char* name) {
#ifdef __APPLE__
    pthread_setname_np(name);
    // HINOKI: the threads that pace the game on the performance cores
    {
        const std::string_view thread_name{name};
        if (thread_name == "VulkanWorker" || thread_name == "VulkanPresent" || thread_name == "Azahar") {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        } else if (thread_name.find("Shader") != std::string_view::npos ||
                   thread_name.find("Pipeline") != std::string_view::npos ||
                   thread_name.find("Worker") != std::string_view::npos) {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
        }
    }""")
edit(TH, """void SetCurrentThreadPriority(ThreadPriority new_priority) {
    pthread_t this_thread = pthread_self();
""", """void SetCurrentThreadPriority(ThreadPriority new_priority) {
#ifdef __APPLE__
    // HINOKI: on Apple platforms the QoS class decides the cores (and the priority)
    pthread_set_qos_class_self_np(new_priority >= ThreadPriority::High ? QOS_CLASS_USER_INTERACTIVE
                                  : new_priority == ThreadPriority::Normal ? QOS_CLASS_USER_INITIATED
                                                                           : QOS_CLASS_UTILITY,
                                  0);
    return;
#endif
    pthread_t this_thread = pthread_self();
""")
edit(TH, "#include <mach/mach.h>\n", "#include <mach/mach.h>\n#include <pthread.h>\n#include <pthread/qos.h> // HINOKI\n#include <string_view>\n")

# ---- 2j. triangle fans on the GPU ----
# Metal has no triangle fans, so MoltenVK reports none and every fan draw used to skip the GPU path:
# the CPU then ran the game's vertex shader for each vertex in the PICA interpreter, the slowest path
# Azahar has. Draw a fan as a triangle list instead (0,i,i+1), with an index buffer built here.
VKR = "src/video_core/renderer_vulkan/vk_rasterizer.cpp"
VKRH = "src/video_core/renderer_vulkan/vk_rasterizer.h"
edit(VKRH, """    /// Setup index array for AccelerateDrawBatch
    void SetupIndexArray();
""", """    /// Setup index array for AccelerateDrawBatch
    void SetupIndexArray();

    /// HINOKI: a triangle fan as a triangle list (no fans in Metal); returns the index count
    u32 HinokiSetupFanIndices(bool is_indexed);
    bool hinoki_fan_as_list = false;
""")
edit(VKR, """    pipeline_info.state.rasterization.topology.Assign(regs.pipeline.triangle_topology);
    if (regs.pipeline.triangle_topology == TriangleTopology::Fan &&
        !instance.IsTriangleFanSupported()) {
        LOG_DEBUG(Render_Vulkan,
                  "Skipping accelerated draw with unsupported triangle fan topology");
        return false;
    }
""", """    pipeline_info.state.rasterization.topology.Assign(regs.pipeline.triangle_topology);
    // HINOKI: no fans in Metal: the fan is drawn as a triangle list (HinokiSetupFanIndices)
    hinoki_fan_as_list = false;
    if (regs.pipeline.triangle_topology == TriangleTopology::Fan &&
        !instance.IsTriangleFanSupported()) {
        if (regs.pipeline.num_vertices < 3) {
            return true; // not a single triangle
        }
        hinoki_fan_as_list = true;
        pipeline_info.state.rasterization.topology.Assign(TriangleTopology::List);
    }
""")
edit(VKR, """bool RasterizerVulkan::AccelerateDrawBatchInternal(bool is_indexed) {
    if (is_indexed) {
        SetupIndexArray();
    }
""", """bool RasterizerVulkan::AccelerateDrawBatchInternal(bool is_indexed) {
    // HINOKI: a fan becomes an indexed triangle list
    u32 hinoki_count = regs.pipeline.num_vertices;
    s32 hinoki_vertex_offset = -static_cast<s32>(vertex_info.vs_input_index_min);
    if (hinoki_fan_as_list) {
        hinoki_count = HinokiSetupFanIndices(is_indexed);
        if (!is_indexed) {
            hinoki_vertex_offset = 0; // the vertex buffer starts at the fan's first vertex
        }
        is_indexed = true;
    } else if (is_indexed) {
        SetupIndexArray();
    }
""")
edit(VKR, """    const DrawParams params = {
        .vertex_count = regs.pipeline.num_vertices,
        .vertex_offset = -static_cast<s32>(vertex_info.vs_input_index_min),""", """    const DrawParams params = {
        .vertex_count = hinoki_count, // HINOKI
        .vertex_offset = hinoki_vertex_offset,""")
edit(VKR, """void RasterizerVulkan::SetupIndexArray() {
    const bool index_u8""", """u32 RasterizerVulkan::HinokiSetupFanIndices(bool is_indexed) {
    // HINOKI: fan (v0, v1, ..., vn-1) -> list (v0,v1,v2) (v0,v2,v3) ... in 32-bit indices
    const u32 count = regs.pipeline.num_vertices;
    const u32 triangles = count - 2;
    const u32 out_count = triangles * 3;
    const u32 out_size = out_count * sizeof(u32);

    const u8* index_data = nullptr;
    const bool index_u16 = regs.pipeline.index_array.format != 0;
    if (is_indexed) {
        index_data =
            memory.GetPhysicalPointer(regs.pipeline.vertex_attributes.GetPhysicalBaseAddress() +
                                      regs.pipeline.index_array.offset);
    }
    const auto source = [&](u32 i) -> u32 {
        if (!index_data) {
            return i;
        }
        if (index_u16) {
            u16 value;
            std::memcpy(&value, index_data + i * 2, sizeof(value));
            return value;
        }
        return index_data[i];
    };

    auto [index_ptr, index_offset, _] = stream_buffer.Map(out_size, 4);
    u32* out = reinterpret_cast<u32*>(index_ptr);
    const u32 first = source(0);
    for (u32 i = 0; i < triangles; i++) {
        out[i * 3 + 0] = first;
        out[i * 3 + 1] = source(i + 1);
        out[i * 3 + 2] = source(i + 2);
    }
    stream_buffer.Commit(out_size);

    scheduler.Record([this, index_offset = index_offset](vk::CommandBuffer cmdbuf) {
        cmdbuf.bindIndexBuffer(stream_buffer.Handle(), index_offset, vk::IndexType::eUint32);
    });
    return out_count;
}

void RasterizerVulkan::SetupIndexArray() {
    const bool index_u8""")

# ---- 2k. PICA shader JIT on iOS ----
# Vertex shaders the GPU can't run (geometry shader draws, immediate-mode draws) run on the CPU. On iOS
# that was always the interpreter: the shader JIT wanted memory that is writable and executable at
# once. Its code now goes into Hinoki's JIT pool (read-execute view plus a writable alias), many
# shaders to a region; if the pool can't lend any, that one shader falls back to the interpreter.
SJA = "src/video_core/shader/shader_jit_a64_compiler.cpp"
SJAH = "src/video_core/shader/shader_jit_a64_compiler.h"
edit(SJAH, """                reinterpret_cast<const std::byte*>(code_mem->ptr()) +
                    instruction_labels[offset].offset());""", """                hinoki_exec_base + instruction_labels[offset].offset()); // HINOKI""")
edit(SJAH, """    std::vector<u32> code_vec;
    std::unique_ptr<oaknut::CodeBlock> code_mem;
""", """    std::vector<u32> code_vec;
    std::unique_ptr<oaknut::CodeBlock> code_mem;
    // HINOKI: where the compiled code runs from (Hinoki's JIT pool on iOS, else code_mem)
    const std::byte* hinoki_exec_base = nullptr;
    std::shared_ptr<void> hinoki_pool_ref;
""")
edit(SJAH, "#include <optional>\n", "#include <memory> // HINOKI\n#include <optional>\n")
edit(SJA, "\nnamespace Pica::Shader {\n", r"""
// HINOKI: code memory lent by Hinoki (set by azh_init; null elsewhere)
extern "C" {
extern bool (*hinoki_jit_take)(std::size_t, void**, void**) __attribute__((weak));
extern void (*hinoki_jit_return)(void*, void*, std::size_t) __attribute__((weak));
}
#if defined(__APPLE__)
#include <libkern/OSCacheControl.h>
#endif
#include <mutex>

namespace {
// HINOKI: many compiled shaders share one 4 MiB region of Hinoki's JIT pool; the regions go back
// when the last shader using them is gone (the game ended)
struct HinokiShaderPool {
    struct Chunk {
        std::byte* rx;
        std::byte* rw;
        std::size_t size;
        std::size_t used;
    };
    std::mutex mutex;
    std::vector<Chunk> chunks;
    std::size_t live = 0;

    static bool Available() {
        return &hinoki_jit_take != nullptr && hinoki_jit_take != nullptr;
    }

    bool Take(std::size_t size, std::byte** rx, std::byte** rw) {
        std::scoped_lock lock{mutex};
        size = (size + 63) & ~std::size_t{63};
        for (auto& chunk : chunks) {
            if (chunk.size - chunk.used >= size) {
                *rx = chunk.rx + chunk.used;
                *rw = chunk.rw + chunk.used;
                chunk.used += size;
                live++;
                return true;
            }
        }
        const std::size_t chunk_size = std::max<std::size_t>(size, 4 * 1024 * 1024);
        void* x = nullptr;
        void* w = nullptr;
        if (!hinoki_jit_take(chunk_size, &x, &w)) {
            return false;
        }
        chunks.push_back({static_cast<std::byte*>(x), static_cast<std::byte*>(w), chunk_size, size});
        *rx = chunks.back().rx;
        *rw = chunks.back().rw;
        live++;
        return true;
    }

    void Release() {
        std::scoped_lock lock{mutex};
        if (live == 0 || --live != 0) {
            return;
        }
        for (const auto& chunk : chunks) {
            if (&hinoki_jit_return != nullptr && hinoki_jit_return != nullptr) {
                hinoki_jit_return(chunk.rx, chunk.rw, chunk.size);
            }
        }
        chunks.clear();
    }
};

HinokiShaderPool& GetHinokiShaderPool() {
    static HinokiShaderPool pool;
    return pool;
}
} // namespace

namespace Pica::Shader {
""")
edit(SJA, """    code_mem = std::make_unique<oaknut::CodeBlock>(code_size);
    code_mem->unprotect();

    program = reinterpret_cast<CompiledShader*>(reinterpret_cast<std::byte*>(code_mem->ptr()) +
                                                program_offset);

    // Copy to executable memory
    std::memcpy(code_mem->ptr(), code_vec.data(), code_vec.size() * sizeof(u32));

    // Memory is ready to execute
    code_mem->protect();
    code_mem->invalidate_all();
""", """    std::byte* rx = nullptr;
    std::byte* rw = nullptr;
    if (HinokiShaderPool::Available() && GetHinokiShaderPool().Take(code_size, &rx, &rw)) {
        // HINOKI: into Hinoki's JIT pool (write through the alias, run from the read-execute view)
        hinoki_pool_ref = std::shared_ptr<void>(reinterpret_cast<void*>(1),
                                                [](void*) { GetHinokiShaderPool().Release(); });
        std::memcpy(rw, code_vec.data(), code_size);
#if defined(__APPLE__)
        sys_icache_invalidate(rx, code_size);
#endif
        hinoki_exec_base = rx;
        program = reinterpret_cast<CompiledShader*>(rx + program_offset);
    } else {
    code_mem = std::make_unique<oaknut::CodeBlock>(code_size);
    code_mem->unprotect();

    program = reinterpret_cast<CompiledShader*>(reinterpret_cast<std::byte*>(code_mem->ptr()) +
                                                program_offset);

    // Copy to executable memory (HINOKI: through the writable view)
    std::memcpy(code_mem->wptr(), code_vec.data(), code_vec.size() * sizeof(u32));

    // Memory is ready to execute
    code_mem->protect();
    code_mem->invalidate_all();
    hinoki_exec_base = reinterpret_cast<const std::byte*>(code_mem->ptr()); // HINOKI
    }
""")
SJ = "src/video_core/shader/shader_jit.cpp"
edit(SJ, '#include "video_core/shader/shader_jit.h"\n', '#include "video_core/shader/shader_jit.h"\n#include "video_core/shader/shader_interpreter.h" // HINOKI\n')
edit(SJ, """        auto shader = std::make_unique<JitShader>();
        shader->Compile(&setup.GetProgramCode(), &setup.GetSwizzleData());
        setup.cached_shader = shader.get();
        cache.emplace_hint(iter, cache_key, std::move(shader));""", """        auto shader = std::make_unique<JitShader>();
        try {
            shader->Compile(&setup.GetProgramCode(), &setup.GetSwizzleData());
        } catch (const std::bad_alloc&) {
            // HINOKI: no code memory for it: this shader runs in the interpreter
            LOG_WARNING(HW_GPU, "Shader JIT: no code memory, using the interpreter for a shader");
            shader.reset();
        }
        setup.cached_shader = shader.get();
        cache.emplace_hint(iter, cache_key, std::move(shader));""")
edit(SJ, """    ASSERT(setup.cached_shader != nullptr);

    MICROPROFILE_SCOPE(GPU_Shader);
""", """    if (setup.cached_shader == nullptr) { // HINOKI: compiled without code memory
        static const InterpreterEngine interpreter;
        interpreter.Run(setup, state);
        return;
    }

    MICROPROFILE_SCOPE(GPU_Shader);
""")

# ---- 2l. frame pacing that matches the screen ----
# The 3DS draws 59.83 frames a second and the phone's screen refreshes 60 (or 120) times. The 0.3%
# difference made a frame show twice every ~6 seconds: a small, regular hitch. Running 0.28% faster
# (inaudible; audio stretching absorbs it) gives every refresh a new frame. Hinoki turns it on and off.
PS = "src/core/perf_stats.cpp"
edit(PS, "\nnamespace Core {\n", """
// HINOKI: speed factor that matches the screen's refresh (set by Hinoki; null elsewhere)
extern "C" double (*hinoki_pace_scale)(void) __attribute__((weak));

namespace Core {
""")
edit(PS, """    double sleep_scale = Settings::GetFrameLimit() / 100.0;
""", """    double sleep_scale = Settings::GetFrameLimit() / 100.0;
    if (Settings::GetFrameLimit() == 100 && &hinoki_pace_scale != nullptr && hinoki_pace_scale) {
        sleep_scale *= hinoki_pace_scale(); // HINOKI
    }
""")

# ---- 2m. MoltenVK settings are 32-bit booleans ----
# The settings were passed as pointers to C++ bools (1 byte) where MoltenVK reads 4: the other three
# bytes were whatever followed on the stack
VKP2 = "src/video_core/renderer_vulkan/vk_platform.cpp"
edit(VKP2, """    const auto synchronous_queue_submits = Settings::values.async_presentation.GetValue();
    // If the device is lost, make an attempt to resume if possible to avoid crashes.
    constexpr auto resume_lost_device = true;
    // Maximize concurrency to improve shader compilation performance.
    constexpr auto maximize_concurrent_compilation = true;""", """    const VkBool32 synchronous_queue_submits =
        Settings::values.async_presentation.GetValue() ? VK_TRUE : VK_FALSE; // HINOKI: VkBool32
    // If the device is lost, make an attempt to resume if possible to avoid crashes.
    const VkBool32 resume_lost_device = VK_TRUE;
    // Maximize concurrency to improve shader compilation performance.
    const VkBool32 maximize_concurrent_compilation = VK_TRUE;""")


# ---- 2n. caches and logs that survive iOS closing the app ----
# Azahar saves the driver pipeline cache only when a game shuts down cleanly, and writes its log
# file only on errors or at exit. On a phone the app is usually swiped away or killed in the
# background instead: every session compiled its pipelines again (hitches in the first minutes),
# and the last minutes of the log (the Perf lines) were lost.
BH = "src/common/logging/backend.h"
edit(BH, """/// Explictily stops the logger thread and flushes the buffers
void Stop();
""", """/// Explictily stops the logger thread and flushes the buffers
void Stop();

/// HINOKI: writes what the backends hold to disk now (the app may be killed without Stop)
void Flush();
""")
BC = "src/common/logging/backend.cpp"
edit(BC, """    static void Stop() {
        instance->StopBackendThread();
    }
""", """    static void Stop() {
        instance->StopBackendThread();
    }

    static void FlushBackends() { // HINOKI
        if (instance) {
            instance->ForEachBackend([](Backend& backend) { backend.Flush(); });
        }
    }
""")
edit(BC, """void Stop() {
    if (logging_initialized) {
        Impl::Stop();
    }
}
""", """void Stop() {
    if (logging_initialized) {
        Impl::Stop();
    }
}

void Flush() { // HINOKI
    if (logging_initialized) {
        Impl::FlushBackends();
    }
}
""")
RI = "src/video_core/rasterizer_interface.h"
edit(RI, """    virtual void SwitchDiskResources([[maybe_unused]] u64 title_id) {}
""", """    virtual void SwitchDiskResources([[maybe_unused]] u64 title_id) {}

    /// HINOKI: saves what is only written at shutdown (the Vulkan driver's pipeline cache)
    virtual void SaveDiskResources() {}
""")
VRH = "src/video_core/renderer_vulkan/vk_rasterizer.h"
edit(VRH, """    void SwitchDiskResources(u64 title_id) override;
""", """    void SwitchDiskResources(u64 title_id) override;
    void SaveDiskResources() override { pipeline_cache.HinokiSaveDriverCache(); } // HINOKI
""")
VPH = "src/video_core/renderer_vulkan/vk_pipeline_cache.h"
edit(VPH, """    void SaveDriverPipelineDiskCache();
""", """    void SaveDriverPipelineDiskCache();

public:
    /// HINOKI: once the compiles in flight are done (called while the game is paused)
    void HinokiSaveDriverCache() {
        pipeline_workers.WaitForRequests();
        shader_workers.WaitForRequests();
        SaveDriverPipelineDiskCache();
    }

private:
""")

print("Azahar prepared for Hinoki")
