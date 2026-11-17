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
   - audio: Hinoki's RemoteIO output in the sink list
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

print("Azahar prepared for Hinoki")
