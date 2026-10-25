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

#include <mem/functions.h>
#include <mem/state.h>

#include <util/align.h>
#include <util/log.h>

#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstring>
#include <iterator>
#include <mutex>
#include <utility>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#else
#include <csignal>
#include <sys/mman.h>
#include <unistd.h>
#endif

constexpr uint32_t STANDARD_PAGE_SIZE = KiB(4);
constexpr size_t TOTAL_MEM_SIZE = GiB(4);
constexpr bool LOG_PROTECT = false;
#ifdef NDEBUG
constexpr bool PAGE_NAME_TRACKING = false;
#else
constexpr bool PAGE_NAME_TRACKING = true;
#endif

// TODO: support multiple handlers
static std::atomic<uintptr_t> g_unhandled_host{ 0 };
static std::atomic<uint32_t> g_unhandled_guest{ 0 };
static std::atomic<bool> g_unhandled_write{ false };
static std::atomic<uintptr_t> g_unhandled_pc{ 0 };
static std::atomic<uintptr_t> g_unhandled_lr{ 0 };
static std::atomic<int> g_unhandled_code{ 0 };
static MemState *g_mem_for_reports = nullptr;

void last_unhandled_access(uintptr_t &host_address, uint32_t &guest_address, bool &write) noexcept {
    host_address = g_unhandled_host.load();
    guest_address = g_unhandled_guest.load();
    write = g_unhandled_write.load();
}

void last_unhandled_code(uintptr_t &pc, uintptr_t &lr, int &si_code) noexcept {
    pc = g_unhandled_pc.load();
    lr = g_unhandled_lr.load();
    si_code = g_unhandled_code.load();
}

static AccessViolationHandler access_violation_handler;
static void register_access_violation_handler(const AccessViolationHandler &handler);

static Address alloc_inner(MemState &state, uint32_t start_page, uint32_t page_count, const char *name, const bool force);
static void delete_memory(uint8_t *memory);

#ifdef _WIN32
static std::string get_error_msg() {
    return std::system_category().message(GetLastError());
}
#else
static std::string get_error_msg() {
    return strerror(errno);
}
#endif

// A guest arena reserved before other large mappings (e.g. the iOS JIT region
// pool) could fragment the address space; the next init() adopts it.
// From Tsubomi by 125hz (https://github.com/125hz/Tsubomi).
static void *g_prereserved_memory = nullptr;

static GuestBackingProvider g_backing_provider = nullptr;

void set_guest_backing_provider(GuestBackingProvider provider) {
    g_backing_provider = provider;
}

bool prereserve_guest_memory() {
#ifdef _WIN32
    // Not needed on desktop: the address space is large and nothing else
    // competes for it before init() runs.
    return true;
#else
    if (g_prereserved_memory)
        return true;
    void *preferred_address = reinterpret_cast<void *>(1ULL << 34);
    void *memory = mmap(preferred_address, TOTAL_MEM_SIZE, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0);
    if (memory == MAP_FAILED) {
        LOG_CRITICAL("Guest memory prereservation failed: {}", get_error_msg());
        return false;
    }
    g_prereserved_memory = memory;
    return true;
#endif
}

bool init(MemState &state, const bool use_page_table) {
#ifdef _WIN32
    SYSTEM_INFO system_info = {};
    GetSystemInfo(&system_info);
    state.host_page_size = system_info.dwPageSize;
#else
    state.host_page_size = static_cast<int>(sysconf(_SC_PAGESIZE));
#endif

    assert(state.host_page_size >= 4096); // Limit imposed by Unicorn.

    state.invalid_access_logged.clear();

    void *preferred_address = reinterpret_cast<void *>(1ULL << 34);

#ifdef _WIN32
    state.memory = Memory(static_cast<uint8_t *>(VirtualAlloc(preferred_address, TOTAL_MEM_SIZE, MEM_RESERVE, PAGE_NOACCESS)), delete_memory);
    if (!state.memory) {
        // fallback
        state.memory = Memory(static_cast<uint8_t *>(VirtualAlloc(nullptr, TOTAL_MEM_SIZE, MEM_RESERVE, PAGE_NOACCESS)), delete_memory);

        if (!state.memory) {
            LOG_CRITICAL("VirtualAlloc failed: {}", get_error_msg());
            return false;
        }
    }
#else
    if (g_prereserved_memory) {
        state.memory = Memory(static_cast<uint8_t *>(g_prereserved_memory), delete_memory);
        g_prereserved_memory = nullptr;
    } else {
        // http://man7.org/linux/man-pages/man2/mmap.2.html
        const int prot = PROT_NONE;
        const int flags = MAP_PRIVATE | MAP_ANONYMOUS;
        const int fd = 0;
        const off_t offset = 0;
        // preferred_address is only a hint for mmap, if it can't use it, the kernel will choose itself the address
        state.memory = Memory(static_cast<uint8_t *>(mmap(preferred_address, TOTAL_MEM_SIZE, prot, flags, fd, offset)), delete_memory);
        if (state.memory.get() == MAP_FAILED) {
            LOG_CRITICAL("mmap failed {}", get_error_msg());
            return false;
        }
    }
#endif

#ifndef _WIN32
    if (g_backing_provider) {
        // Where a game's memory goes (SceSysmem): main RAM first, then CDRAM and uncached main RAM.
        // Pages stay inaccessible until the allocator hands them out, exactly as without helpers.
        struct Range {
            Address start;
            uint64_t size;
        };
        constexpr Range ranges[] = { { 0x80000000, GiB(1) }, { 0x60000000, MiB(256) }, { 0x70000000, MiB(256) } };
        uint64_t backed = 0;
        for (size_t i = 0; i < std::size(ranges); i++)
            backed += g_backing_provider(state.memory.get() + ranges[i].start, ranges[i].size, i + 1 == std::size(ranges));
        if (backed)
            LOG_INFO("RAM helpers back {} MiB of the guest's memory", backed / MiB(1));
    }
#endif

    const size_t table_length = TOTAL_MEM_SIZE / STANDARD_PAGE_SIZE;
    state.alloc_table = AllocPageTable(new AllocMemPage[table_length]);
    memset(state.alloc_table.get(), 0, sizeof(AllocMemPage) * table_length);

    state.allocator.set_maximum(table_length);

    const auto handler = [&state](uint8_t *addr, bool write) noexcept {
        return handle_access_violation(state, addr, write);
    };
    register_access_violation_handler(handler);
    g_mem_for_reports = &state;
    g_unhandled_host = 0;
    g_unhandled_guest = 0;
    g_unhandled_pc = 0;
    g_unhandled_lr = 0;
    g_unhandled_code = 0;

    const Address null_address = alloc_inner(state, 0, state.host_page_size / STANDARD_PAGE_SIZE, "null", true);
    assert(null_address == 0);
#ifdef _WIN32
    DWORD old_protect = 0;
    const BOOL ret = VirtualProtect(state.memory.get(), state.host_page_size, PAGE_NOACCESS, &old_protect);
    LOG_CRITICAL_IF(!ret, "VirtualAlloc failed: {}", get_error_msg());
#else
    const int ret = mprotect(state.memory.get(), state.host_page_size, PROT_NONE);
    LOG_CRITICAL_IF(ret == -1, "mprotect failed: {}", get_error_msg());
#endif

    state.use_page_table = use_page_table;
    if (use_page_table) {
        state.page_table = PageTable(new PagePtr[TOTAL_MEM_SIZE / KiB(4)]);
        // we use an absolute offset (it is faster), so each entry is the same
        std::fill_n(state.page_table.get(), TOTAL_MEM_SIZE / KiB(4), state.memory.get());
    }

    return true;
}

static void delete_memory(uint8_t *memory) {
    if (memory != nullptr) {
#ifdef _WIN32
        const BOOL ret = VirtualFree(memory, 0, MEM_RELEASE);
        assert(ret);
#else
        munmap(memory, TOTAL_MEM_SIZE);
#endif
    }
}

bool is_valid_addr(const MemState &state, Address addr) {
    const uint32_t page_num = addr / STANDARD_PAGE_SIZE;
    return addr && state.allocator.free_slot_count(page_num, page_num + 1) == 0;
}

bool is_valid_addr_range(const MemState &state, Address start, Address end) {
    const uint32_t start_page = start / STANDARD_PAGE_SIZE;
    const uint32_t end_page = (end + STANDARD_PAGE_SIZE - 1) / STANDARD_PAGE_SIZE;
    return state.allocator.free_slot_count(start_page, end_page) == 0;
}

static Address alloc_inner(MemState &state, uint32_t start_page, uint32_t page_count, const char *name, const bool force) {
    int page_num;
    if (force) {
        if (state.allocator.allocate_at(start_page, page_count) < 0) {
            return 0;
        }
        page_num = start_page;
    } else {
        page_num = state.allocator.allocate_from(start_page, page_count, false);
        if (page_num < 0)
            return 0;
    }

    const uint32_t size = page_count * STANDARD_PAGE_SIZE;
    const Address addr = page_num * STANDARD_PAGE_SIZE;

    const Address commit_start = align_down(addr, state.host_page_size);
    const Address commit_end = align(addr + size, state.host_page_size);
    const uint32_t commit_size = commit_end - commit_start;
    uint8_t *const commit_ptr = &state.memory[commit_start];

    // Make memory chunk available to access
#ifdef _WIN32
    const void *const ret = VirtualAlloc(commit_ptr, commit_size, MEM_COMMIT, PAGE_READWRITE);
    LOG_CRITICAL_IF(!ret, "VirtualAlloc failed: {}", get_error_msg());
#else
    const int ret = mprotect(commit_ptr, commit_size, PROT_READ | PROT_WRITE);
    LOG_CRITICAL_IF(ret == -1, "mprotect failed: {}", get_error_msg());
#endif
    std::memset(&state.memory[addr], 0, size);

    AllocMemPage &page = state.alloc_table[page_num];
    assert(!page.allocated);
    page.allocated = 1;
    page.size = page_count;

    if (PAGE_NAME_TRACKING) {
        state.page_name_map.emplace(page_num, name);
    }

    return addr;
}

Address alloc_aligned(MemState &state, uint32_t size, const char *name, unsigned int alignment, Address start_addr) {
    if (alignment == 0)
        return alloc(state, size, name, start_addr);
    const std::lock_guard<std::mutex> lock(state.generation_mutex);
    size += alignment;
    const uint32_t page_count = align(size, STANDARD_PAGE_SIZE) / STANDARD_PAGE_SIZE;
    const Address addr = alloc_inner(state, start_addr / STANDARD_PAGE_SIZE, page_count, name, false);
    const Address align_addr = align(addr, alignment);
    const uint32_t page_num = addr / STANDARD_PAGE_SIZE;
    const uint32_t align_page_num = align_addr / STANDARD_PAGE_SIZE;

    if (page_num != align_page_num) {
        AllocMemPage &page = state.alloc_table[page_num];
        AllocMemPage &align_page = state.alloc_table[align_page_num];
        const uint32_t remnant_front = align_page_num - page_num;
        state.allocator.free(page_num, remnant_front);
        page.allocated = 0;
        align_page.allocated = 1;
        align_page.size = page.size - remnant_front;
    }

    return align_addr;
}

static void align_to_page(MemState &state, Address &addr, Address &size) {
    // Protections must cover whole host pages: mprotect works on host pages (16 KiB on Apple
    // silicon), so a 4 KiB segment would share its page with unprotected memory. A write there
    // faulted with no segment to match, the page was unprotected anyway, and the segment silently
    // stopped trapping writes (stale textures and GPU buffers).
    const Address page = std::max<Address>(STANDARD_PAGE_SIZE, static_cast<Address>(state.host_page_size));
    const Address end = align(addr + size, page);
    addr = align_down(addr, page);
    size = end - addr;
}

static void note_protected_pages(MemState &state, Address addr, uint32_t size, bool is_protected) {
    if (size == 0)
        return;
    const Address first = align_down(addr, state.host_page_size);
    const Address last = align_down(addr + size - 1, state.host_page_size);
    const std::lock_guard<std::mutex> lock(state.protected_pages_mutex);
    for (Address page = first;; page += state.host_page_size) {
        if (is_protected)
            state.protected_pages.insert(page);
        else
            state.protected_pages.erase(page);
        if (page == last)
            break;
    }
}

void unprotect_inner(MemState &state, Address addr, uint32_t size) {
    if (LOG_PROTECT) {
        fmt::print("Unprotect: {} {}\n", log_hex(addr), size);
    }
    uint8_t *addr_ptr = state.use_page_table ? state.page_table[addr / KiB(4)] : state.memory.get();

    uint8_t *target = &addr_ptr[addr];
    uint8_t *aligned_start = reinterpret_cast<uint8_t *>(
        align_down(reinterpret_cast<uintptr_t>(target), state.host_page_size));
    uint8_t *aligned_end = reinterpret_cast<uint8_t *>(align(reinterpret_cast<uintptr_t>(target + size), state.host_page_size));
    size_t aligned_size = aligned_end - aligned_start;

#ifdef _WIN32
    DWORD old_protect = 0;
    const BOOL ret = VirtualProtect(aligned_start, aligned_size, PAGE_READWRITE, &old_protect);
    LOG_CRITICAL_IF(!ret, "VirtualAlloc failed: {}", get_error_msg());
    if (ret)
        note_protected_pages(state, addr, size, false);
#else
    const int ret = mprotect(aligned_start, aligned_size, PROT_READ | PROT_WRITE);
    LOG_CRITICAL_IF(ret == -1, "mprotect failed: {}", get_error_msg());
    if (ret != -1)
        note_protected_pages(state, addr, size, false);
#endif
}

void protect_inner(MemState &state, Address addr, uint32_t size, const MemPerm perm) {
    note_protected_pages(state, addr, size, true);
    uint8_t *addr_ptr = state.use_page_table ? state.page_table[addr / KiB(4)] : state.memory.get();

    uint8_t *target = &addr_ptr[addr];
    uint8_t *aligned_start = reinterpret_cast<uint8_t *>(
        align_down(reinterpret_cast<uintptr_t>(target), state.host_page_size));
    uint8_t *aligned_end = reinterpret_cast<uint8_t *>(align(reinterpret_cast<uintptr_t>(target + size), state.host_page_size));
    size_t aligned_size = aligned_end - aligned_start;

#ifdef _WIN32
    DWORD old_protect = 0;
    const BOOL ret = VirtualProtect(aligned_start, aligned_size, (perm == MemPerm::None) ? PAGE_NOACCESS : ((perm == MemPerm::ReadOnly) ? PAGE_READONLY : PAGE_READWRITE), &old_protect);
    LOG_CRITICAL_IF(!ret, "VirtualAlloc failed: {}", get_error_msg());
#else
    const int ret = mprotect(aligned_start, aligned_size, (perm == MemPerm::None) ? PROT_NONE : ((perm == MemPerm::ReadOnly) ? PROT_READ : (PROT_READ | PROT_WRITE)));
    LOG_CRITICAL_IF(ret == -1, "mprotect failed: {}", get_error_msg());
#endif
}

// A write hit a protected host page that no segment covers exactly (host pages are 16 KiB on Apple
// silicon, so one page can hold several guest regions). The page gets unprotected so the game can go
// on; every segment overlapping it loses its protection with it, so tell their trackers (texture
// cache, buffer trapping) now: before, they silently stopped seeing changes (stale textures and
// GPU buffers: stray geometry, missing scenery). Called with protect_mutex held.
static void release_host_page(MemState &state, Address vaddr, bool write) {
    const Address page = std::max<Address>(STANDARD_PAGE_SIZE, static_cast<Address>(state.host_page_size));
    const Address page_begin = align_down(vaddr, page);
    const Address page_end = page_begin + page;
    // segments never overlap each other and the tree is sorted by descending start: walk down from
    // the last segment starting inside the page until one ends before it
    auto it = state.protect_tree.lower_bound(page_end - 1);
    while (it != state.protect_tree.end() && it->first + it->second.size > page_begin) {
        for (auto &[block_addr, block] : it->second.blocks)
            block.callback(vaddr, write);
        unprotect_inner(state, it->first, it->second.size);
        it = state.protect_tree.erase(it);
    }
    unprotect_inner(state, page_begin, page);
}

bool handle_access_violation(MemState &state, uint8_t *addr, bool write) noexcept {
    const uintptr_t memory_addr = reinterpret_cast<uintptr_t>(state.memory.get());
    const uintptr_t fault_addr = reinterpret_cast<uintptr_t>(addr);

    Address vaddr = 0;
    const std::unique_lock<std::mutex> lock(state.protect_mutex);
    if (fault_addr < memory_addr || fault_addr >= memory_addr + TOTAL_MEM_SIZE) {
        if (state.use_page_table) {
            // this may come from an external mapping
            uint64_t addr_val = std::bit_cast<uint64_t>(addr);
            auto it = state.external_mapping.lower_bound(addr_val);
            if (it != state.external_mapping.end() && addr_val < it->first + it->second.size) {
                vaddr = static_cast<Address>(addr_val - it->first + it->second.address);
            } else {
                return false;
            }
        } else {
            return false;
        }
    } else {
        vaddr = static_cast<Address>(fault_addr - memory_addr);
    }

    if (!is_valid_addr(state, vaddr)) {
#if defined(VITA3K_PLATFORM_IOS)
        // A game touching guest memory it never allocated (Madden NFL 13 with surface sync and high
        // accuracy wrote to 0xFF000A0C) closed the whole app. A Vita would have faulted the game
        // too, but here it usually is an emulation gap, so give that page zeroed scratch memory and
        // let the game go on. Only for pages backed by the reserved guest range itself.
        const bool in_reserved_range = fault_addr >= memory_addr && fault_addr < memory_addr + TOTAL_MEM_SIZE;
        if (in_reserved_range) {
            // also tells the trackers of any protected region sharing that host page
            release_host_page(state, vaddr, write);
            static std::atomic<int> logged{ 0 };
            if (logged.fetch_add(1) < 20)
                LOG_WARN("The game {} unallocated guest memory at 0x{:X}: gave it a zeroed page", write ? "wrote to" : "read", vaddr);
            return true;
        }
#endif
        return false;
    }
    if (LOG_PROTECT) {
        fmt::print("Access: {}\n", log_hex(vaddr));
    }

    {
        const std::lock_guard<std::mutex> pages_lock(state.protected_pages_mutex);
        const Address page = align_down(vaddr, state.host_page_size);
        if (page != 0 && !state.protected_pages.contains(page))
            return true;
    }

    auto it = state.protect_tree.lower_bound(vaddr);
    if (it == state.protect_tree.end() || vaddr < it->first || vaddr >= it->first + it->second.size) {
        // keep going: unprotect the page, and let the segments that shared it know
        release_host_page(state, vaddr, write);
        LOG_WARN_ONCE("Write to a protected host page outside any tracked region (address 0x{:X}): released the page", vaddr);
        return true;
    }

    ProtectSegmentInfo &info = it->second;

    Address previous_beg = it->first;
    for (auto &[block_addr, block] : info.blocks) {
        block.callback(vaddr, write);
    }

    unprotect_inner(state, it->first, info.size);
    state.protect_tree.erase(it);

    return true;
}

bool add_protect(MemState &state, Address addr, const uint32_t size, const MemPerm perm, const ProtectCallback &callback) {
    const std::lock_guard<std::mutex> lock(state.protect_mutex);
    ProtectSegmentInfo protect(size, perm);
    align_to_page(state, addr, protect.size);

    ProtectBlockInfo block;
    block.size = size;
    block.callback = callback;

    protect.blocks.emplace(addr, std::move(block));

    auto it = state.protect_tree.lower_bound(addr);
    if (it == state.protect_tree.end() || it->first + it->second.size <= addr) {
        if (it == state.protect_tree.begin())
            it = state.protect_tree.end();
        else
            --it;
    }

    // Merge every segment overlapping the aligned range (not just the requested bytes), so no
    // two segments ever share a host page
    while (it != state.protect_tree.end() && it->first < addr + protect.size) {
        const Address start = std::min(it->first, addr);
        protect.size = std::max(it->first + it->second.size, addr + protect.size) - start;
        addr = start;
        protect.blocks.merge(it->second.blocks); // transfer blocks to the new protect
        protect.perm = most_restrictive_perm(protect.perm, it->second.perm);

        if (it == state.protect_tree.begin()) {
            state.protect_tree.erase(it);
            break;
        }

        // protect tree is in reverse order, so decrease it
        state.protect_tree.erase(it--);
    }

    protect_inner(state, addr, protect.size, protect.perm);

    state.protect_tree.emplace(addr, std::move(protect));
    return true;
}

bool is_protecting(MemState &state, Address addr, MemPerm *perm) {
    const std::lock_guard<std::mutex> lock(state.protect_mutex);
    auto ite = state.protect_tree.lower_bound(addr);

    if (ite != state.protect_tree.end() && addr < ite->first + ite->second.size) {
        if (perm)
            *perm = ite->second.perm;

        return true;
    }

    return false;
}

void add_external_mapping(MemState &mem, Address addr, uint32_t size, uint8_t *addr_ptr) {
    assert((size & 4095) == 0);
    if (!mem.use_page_table)
        return;

    uint64_t addr_value = std::bit_cast<uint64_t>(addr_ptr);
    uint8_t *page_table_entry = addr_ptr - addr;
    uint8_t *original_address = &mem.memory[addr];
    for (int block = 0; block < size / KiB(4); block++) {
        // this is not thread write safe, but hopefully not other thread is busy copying while this happens
        memcpy(addr_ptr + block * KiB(4), original_address + block * KiB(4), KiB(4));
        mem.page_table[addr / KiB(4) + block] = page_table_entry;
    }

    // Protect the now unused original range (catches stray accesses), only the host pages it fully
    // covers: protecting outward would also protect the neighbouring guest memory that shares a
    // 16 KiB host page and is still used from the original memory
    const Address host_page = std::max<Address>(STANDARD_PAGE_SIZE, static_cast<Address>(mem.host_page_size));
    const Address inner_begin = align(addr, host_page);
    const Address inner_end = align_down(addr + size, host_page);
    if (inner_end > inner_begin) {
        // point the first page table entry at the original memory for protect_inner
        mem.page_table[inner_begin / KiB(4)] = mem.memory.get();
        protect_inner(mem, inner_begin, inner_end - inner_begin, MemPerm::None);
        mem.page_table[inner_begin / KiB(4)] = page_table_entry;
    }

    const std::unique_lock<std::mutex> lock(mem.protect_mutex);
    mem.external_mapping[addr_value] = { addr, size };
}

void remove_external_mapping(MemState &mem, uint8_t *addr_ptr, uint32_t size) {
    uint64_t addr_value = std::bit_cast<uint64_t>(addr_ptr);
    MemExternalMapping mapping;
    if (mem.use_page_table) {
        const std::unique_lock<std::mutex> lock(mem.protect_mutex);
        auto it = mem.external_mapping.find(addr_value);
        assert(it != mem.external_mapping.end());

        mapping = it->second;
        mem.external_mapping.erase(it);
    } else {
        mapping.address = static_cast<Address>(addr_ptr - mem.memory.get());
        mapping.size = size;
    }

    // remove all protections on this range
    unprotect_inner(mem, mapping.address, mapping.size);
    {
        const std::unique_lock<std::mutex> lock(mem.protect_mutex);
        auto prot_it = mem.protect_tree.lower_bound(mapping.address);
        // lower_bound is end() when no segment starts at or below the address: don't dereference it
        if (prot_it != mem.protect_tree.end() && prot_it->first + prot_it->second.size <= mapping.address) {
            if (prot_it == mem.protect_tree.begin())
                prot_it = mem.protect_tree.end();
            else
                --prot_it;
        }

        while (prot_it != mem.protect_tree.end() && prot_it->first < mapping.address + mapping.size) {
            // the memory under these segments changes owner: their trackers must reload it
            for (auto &[block_addr, block] : prot_it->second.blocks)
                block.callback(prot_it->first, true);
            if (prot_it == mem.protect_tree.begin()) {
                mem.protect_tree.erase(prot_it);
                break;
            }

            mem.protect_tree.erase(prot_it--);
        }
    }

    if (mem.use_page_table) {
        // unprotect the original memory range (add_external_mapping only protected the host pages
        // it fully covers)
        const Address host_page = std::max<Address>(STANDARD_PAGE_SIZE, static_cast<Address>(mem.host_page_size));
        const Address inner_begin = align(mapping.address, host_page);
        const Address inner_end = align_down(mapping.address + mapping.size, host_page);
        if (inner_end > inner_begin) {
            mem.page_table[inner_begin / KiB(4)] = mem.memory.get();
            unprotect_inner(mem, inner_begin, inner_end - inner_begin);
        }
        // copy back and reset the page table
        for (int block = 0; block < mapping.size / KiB(4); block++) {
            // this is not thread write safe, but hopefully not other thread is busy copying while this happens
            memcpy(&mem.memory[mapping.address] + block * KiB(4), addr_ptr + block * KiB(4), KiB(4));
            mem.page_table[mapping.address / KiB(4) + block] = mem.memory.get();
        }
    }
}

Address alloc(MemState &state, uint32_t size, const char *name, Address start_addr) {
    const std::lock_guard<std::mutex> lock(state.generation_mutex);
    const uint32_t page_count = align(size, STANDARD_PAGE_SIZE) / STANDARD_PAGE_SIZE;
    const Address addr = alloc_inner(state, start_addr / STANDARD_PAGE_SIZE, page_count, name, false);
    return addr;
}

Address alloc_at(MemState &state, Address address, uint32_t size, const char *name) {
    auto addr = try_alloc_at(state, address, size, name);
    LOG_CRITICAL_IF(addr == 0, "Failed to allocate at specific page. Memory address:{}, size:{}, name:{}", log_hex(address), log_hex(size), name);
    return addr;
}

Address try_alloc_at(MemState &state, Address address, uint32_t size, const char *name) {
    const std::lock_guard<std::mutex> lock(state.generation_mutex);
    const uint32_t wanted_page = address / STANDARD_PAGE_SIZE;
    size += address % STANDARD_PAGE_SIZE;
    const uint32_t page_count = align(size, STANDARD_PAGE_SIZE) / STANDARD_PAGE_SIZE;
    const Address addr = alloc_inner(state, wanted_page, page_count, name, true);
    return addr ? address : 0;
}

Block alloc_block(MemState &mem, uint32_t size, const char *name, Address start_addr) {
    const Address address = alloc(mem, size, name, start_addr);
    return Block(address, [&mem](Address stack) {
        free(mem, stack);
    });
}

void free(MemState &state, Address address) {
    const std::lock_guard<std::mutex> lock(state.generation_mutex);
    const uint32_t page_num = address / STANDARD_PAGE_SIZE;
    assert(page_num >= 0);

    if (state.alloc_table == nullptr) {
        LOG_CRITICAL("Freeing unallocated alloc_table");
        return;
    }

    AllocMemPage &page = state.alloc_table[page_num];
    if (!page.allocated) {
        LOG_CRITICAL("Freeing unallocated page");
    }
    page.allocated = 0;

    state.allocator.free(page_num, page.size);
    if (PAGE_NAME_TRACKING) {
        state.page_name_map.erase(page_num);
    }

    assert(!state.use_page_table || state.page_table[address / KiB(4)] == state.memory.get());
    const Address region_start = page_num * STANDARD_PAGE_SIZE;
    const Address region_end = region_start + page.size * STANDARD_PAGE_SIZE;

    Address host_page = align_down(region_start, state.host_page_size);
    Address batch_start = 0;
    uint32_t batch_size = 0;

    while (host_page < region_end) {
        Address host_page_end = host_page + state.host_page_size;
        uint32_t first_guest = host_page / STANDARD_PAGE_SIZE;
        uint32_t last_guest = host_page_end / STANDARD_PAGE_SIZE;

        if (state.allocator.free_slot_count(first_guest, last_guest) == (last_guest - first_guest)) {
            if (batch_size == 0)
                batch_start = host_page;
            batch_size += state.host_page_size;
        } else if (batch_size > 0) {
            uint8_t *memory = &state.memory[batch_start];
#ifdef _WIN32
            const BOOL ret = VirtualFree(memory, batch_size, MEM_DECOMMIT);
            LOG_CRITICAL_IF(!ret, "VirtualFree failed: {}", get_error_msg());
#else
            int ret = mprotect(memory, batch_size, PROT_NONE);
            LOG_CRITICAL_IF(ret == -1, "mprotect failed: {}", get_error_msg());
            ret = madvise(memory, batch_size, MADV_DONTNEED);
            LOG_CRITICAL_IF(ret == -1, "madvise failed: {}", get_error_msg());
#endif
            batch_size = 0;
        }
        host_page = host_page_end;
    }

    if (batch_size > 0) {
        uint8_t *memory = &state.memory[batch_start];
#ifdef _WIN32
        const BOOL ret = VirtualFree(memory, batch_size, MEM_DECOMMIT);
        LOG_CRITICAL_IF(!ret, "VirtualFree failed: {}", get_error_msg());
#else
        int ret = mprotect(memory, batch_size, PROT_NONE);
        LOG_CRITICAL_IF(ret == -1, "mprotect failed: {}", get_error_msg());
        ret = madvise(memory, batch_size, MADV_DONTNEED);
        LOG_CRITICAL_IF(ret == -1, "madvise failed: {}", get_error_msg());
#endif
    }
}

uint32_t mem_available(MemState &state) {
    return state.allocator.free_slot_count(0, state.allocator.max_offset) * STANDARD_PAGE_SIZE;
}

const char *mem_name(Address address, MemState &state) {
    if (PAGE_NAME_TRACKING) {
        return state.page_name_map.find(address / STANDARD_PAGE_SIZE)->second.c_str();
    }
    return "";
}

void deinit_mem(MemState &state) {
    const std::lock_guard<std::mutex> gen_lock(state.generation_mutex);

    {
        const std::lock_guard<std::mutex> prot_lock(state.protect_mutex);
        state.protect_tree.clear();
    }

    state.memory.reset();
    state.alloc_table.reset();
    state.allocator.reset();
    state.page_name_map.clear();
    state.page_table.reset();
    state.external_mapping.clear();
    state.use_page_table = false;
    state.host_page_size = 0;
}

#ifdef _WIN32

static LONG WINAPI exception_handler(PEXCEPTION_POINTERS pExp) noexcept {
    if (pExp->ExceptionRecord->ExceptionCode == EXCEPTION_BREAKPOINT && IsDebuggerPresent()) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    const auto ptr = reinterpret_cast<uint8_t *>(pExp->ExceptionRecord->ExceptionInformation[1]);
    const bool is_writing = pExp->ExceptionRecord->ExceptionInformation[0] == 1;
    const bool is_executing = pExp->ExceptionRecord->ExceptionInformation[0] == 8;

    if (pExp->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && !is_executing) {
        if (access_violation_handler(ptr, is_writing)) {
            return EXCEPTION_CONTINUE_EXECUTION;
        }
    }

    return EXCEPTION_CONTINUE_SEARCH;
}

static void register_access_violation_handler(const AccessViolationHandler &handler) {
    access_violation_handler = handler;
    if (!AddVectoredExceptionHandler(1, exception_handler)) {
        LOG_CRITICAL("Failed to register an exception handler");
    }
}

#else

static void signal_handler(int sig, siginfo_t *info, void *uct) noexcept {
    auto context = static_cast<ucontext_t *>(uct);

#ifdef __aarch64__
#ifdef __APPLE__
    const uint32_t esr = context->uc_mcontext->__es.__esr;
#else
    _aarch64_ctx *ctx = reinterpret_cast<_aarch64_ctx *>(context->uc_mcontext.__reserved);
    // get the ESR register
    while (ctx->magic != ESR_MAGIC) {
        if (ctx->magic == 0)
            [[unlikely]]
            raise(SIGTRAP);
        else
            [[likely]]
            ctx = reinterpret_cast<_aarch64_ctx *>(reinterpret_cast<uint8_t *>(ctx) + ctx->size);
    }

    const uint64_t esr = reinterpret_cast<esr_context *>(ctx)->esr;
#endif
    // https://developer.arm.com/documentation/ddi0595/2021-03/AArch64-Registers/ESR-EL1--Exception-Syndrome-Register--EL1-
    const uint32_t exception_class = static_cast<uint32_t>(esr) >> 26;
    const bool is_executing = (exception_class == 0b100000) || (exception_class == 0b100001);
    const bool is_data_abort = (exception_class == 0b100100) || (exception_class == 0b100101);
    const bool is_writing = is_data_abort && (esr & (1 << 6));
#else
#ifdef __APPLE__
    const uint64_t err = context->uc_mcontext->__es.__err;
#else
    const uint64_t err = context->uc_mcontext.gregs[REG_ERR];
#endif
    const bool is_executing = err & 0x10;
    const bool is_writing = err & 0x2;
#endif

    if (!is_executing) {
        if (access_violation_handler(reinterpret_cast<uint8_t *>(info->si_addr), is_writing)) {
            return;
        }
    }

    const uintptr_t fault = reinterpret_cast<uintptr_t>(info->si_addr);
    uint32_t guest = 0;
    if (g_mem_for_reports && g_mem_for_reports->memory) {
        const uintptr_t base = reinterpret_cast<uintptr_t>(g_mem_for_reports->memory.get());
        if (fault >= base && fault - base < TOTAL_MEM_SIZE)
            guest = static_cast<uint32_t>(fault - base);
    }
    g_unhandled_host = fault;
    g_unhandled_guest = guest;
    g_unhandled_write = is_writing;
    // The code that made the access: the trap raised below reports where it was raised, which is not
    // always the faulting thread's code (a crash report once showed only the main thread asleep)
    uintptr_t fault_pc = 0;
    uintptr_t fault_lr = 0;
#if defined(__APPLE__) && defined(__aarch64__)
    fault_pc = static_cast<uintptr_t>(context->uc_mcontext->__ss.__pc);
    fault_lr = static_cast<uintptr_t>(context->uc_mcontext->__ss.__lr);
#endif
    g_unhandled_pc = fault_pc;
    g_unhandled_lr = fault_lr;
    g_unhandled_code = info->si_code;
    LOG_CRITICAL("Unhandled {} {} 0x{:X} (guest address 0x{:X}){} by code at 0x{:X} (called from 0x{:X}), signal {} code {}",
        is_executing ? "execution" : (is_writing ? "write" : "read"),
        "at", fault, guest, guest ? "" : ": outside guest memory", fault_pc, fault_lr, sig, info->si_code);
    if (auto logger = spdlog::default_logger())
        logger->flush();
    raise(SIGTRAP);
    return;
}

static void register_access_violation_handler(const AccessViolationHandler &handler) {
    access_violation_handler = handler;
    struct sigaction sa;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    sa.sa_sigaction = signal_handler;
    if (sigaction(SIGSEGV, &sa, nullptr) == -1) {
        LOG_CRITICAL("Failed to register an exception handler");
    }
#ifdef __APPLE__
    // When accessing memory region which is PROT_NONE on macOS, it is raising SIGBUS not SIGSEGV.
    // So apply same signal handler to SIGBUS
    if (sigaction(SIGBUS, &sa, nullptr) == -1) {
        LOG_CRITICAL("Failed to register an exception handler to SIGBUS");
    }
#endif
}

#endif
