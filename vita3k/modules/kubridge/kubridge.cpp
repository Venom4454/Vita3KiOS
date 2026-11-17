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

// HLE overrides for kubridge exports that cannot run as LLE.
// kubridge's mem*/exception functions depend on firmware-specific offsets
// and ARM MMU page table manipulation, which don't work in an emulator.
// These HLE implementations provide equivalent functionality using
// Vita3K's memory system.

#include "../SceSysmem/SceSysmemForDriver.h"

#include <module/module.h>

#include <cpu/functions.h>
#include <cpu/state.h>
#include <kernel/state.h>
#include <mem/functions.h>
#include <modules/sysmem_state.h>
#include <util/align.h>
#include <util/log.h>
#include <util/tracy.h>

#include <cstring>

TRACY_MODULE_NAME(kubridge);

// kubridge protection flags
constexpr uint32_t KU_KERNEL_PROT_NONE = 0x00;
constexpr uint32_t KU_KERNEL_PROT_READ = 0x40;
constexpr uint32_t KU_KERNEL_PROT_WRITE = 0x20;
constexpr uint32_t KU_KERNEL_PROT_EXEC = 0x10;

// kubridge commit opt attr
constexpr uint32_t KU_KERNEL_MEM_COMMIT_ATTR_HAS_BASE = 0x1;

struct KuKernelMemCommitOpt {
    uint32_t size;
    uint32_t attr;
    SceUID baseBlock;
    uint32_t baseOffset;
};

struct KuKernelExceptionHandlerOpt {
    uint32_t size;
};

// Page fault callback, called from a signal handler. It notes the abort on this host thread's CPU and
// halts it, so the thread runs the registered abort handler, if any.
static bool abort_aware_fault_callback(Address fault_addr, bool write, Address range_start, uint32_t range_size) {
    CPUState *cpu = get_current_cpu_state();
    if (cpu) {
        cpu->abort_fault_addr.store(fault_addr);
        cpu->abort_pending.store(true);
        stop(*cpu); // Only sets an atomic, so it is signal safe
    }
    return true;
}

// Convert kubridge protection flags to Vita3K MemPerm.
// Note: EXEC is not mapped — dynarmic handles execute permission separately.
static MemPerm ku_prot_to_memperm(uint32_t prot) {
    if (prot & KU_KERNEL_PROT_WRITE)
        return MemPerm::ReadWrite;
    if (prot & KU_KERNEL_PROT_READ)
        return MemPerm::ReadOnly;
    return MemPerm::None;
}

// kuKernelMemProtect — change memory protection on a range.
// Uses add_protect for restrictive permissions (so fault handler can catch access),
// and unprotect_inner to restore access.
EXPORT(int, kuKernelMemProtect, Ptr<void> addr, SceSize len, uint32_t prot) {
    TRACY_FUNC(kuKernelMemProtect, addr, len, prot);
    if (!addr || len == 0)
        return RET_ERROR(SCE_KERNEL_ERROR_INVALID_ARGUMENT);

    const MemPerm perm = ku_prot_to_memperm(prot);

    if (perm == MemPerm::None || perm == MemPerm::ReadOnly) {
        // Use add_protect so fault handler can catch violations gracefully.
        // If an exception handler is registered, the fault callback halts
        // the CPU and the thread then runs the ARM handler.
        const Address va = addr.address();
        add_protect(emuenv.mem, va, len, perm, [va, len](Address fault_addr, bool write) {
            return abort_aware_fault_callback(fault_addr, write, va, len);
        });
    } else {
        // ReadWrite or more permissive — just unprotect
        unprotect_inner(emuenv.mem, addr.address(), len);
    }

    LOG_DEBUG("kuKernelMemProtect: addr={} len={} prot=0x{:02X} -> perm={}",
        log_hex(addr.address()), len, prot, static_cast<int>(perm));
    return 0;
}

// kuKernelMemReserve — reserve virtual address space.
// On real Vita, this allocates virtual address space without physical backing.
// In Vita3K, we allocate real memory immediately (no lazy allocation).
EXPORT(SceUID, kuKernelMemReserve, Ptr<Ptr<void>> addr, SceSize size, SceKernelMemBlockType memBlockType) {
    TRACY_FUNC(kuKernelMemReserve, addr, size, memBlockType);
    if (!addr)
        return RET_ERROR(SCE_KERNEL_ERROR_INVALID_ARGUMENT);

    auto &mem = emuenv.mem;
    const auto state = emuenv.kernel.obj_store.get<SysmemState>();
    const auto guard = std::lock_guard<std::mutex>(state->mutex);

    Address requested_addr = (*addr.get(mem)).address();
    Address allocated_addr;

    if (requested_addr) {
        allocated_addr = alloc_at(mem, requested_addr, size, "kubridge_reserve");
    } else {
        allocated_addr = alloc(mem, size, "kubridge_reserve");
    }

    if (!allocated_addr)
        return RET_ERROR(SCE_KERNEL_ERROR_NO_MEMORY);

    // Store the allocated address back
    *addr.get(mem) = Ptr<void>(allocated_addr);

    // Track it like any other memory block
    const SceUID uid = add_block(*state, "kubridge_reserve", memBlockType, allocated_addr, size);

    LOG_DEBUG("kuKernelMemReserve: addr=0x{:08X} size={} type=0x{:08X} uid=0x{:08X}",
        allocated_addr, size, static_cast<uint32_t>(memBlockType), uid);
    return uid;
}

// kuKernelMemCommit — commit physical pages to a reserved range.
// Memory is already committed at Reserve time. Apply requested protection.
// When baseBlock mirroring is required, this should use add_external_mapping().
EXPORT(int, kuKernelMemCommit, Ptr<void> addr, SceSize len, uint32_t prot, Ptr<KuKernelMemCommitOpt> pOpt) {
    TRACY_FUNC(kuKernelMemCommit, addr, len, prot, pOpt);
    if (!addr || len == 0)
        return RET_ERROR(SCE_KERNEL_ERROR_INVALID_ARGUMENT);

    if (pOpt) {
        auto *opt = pOpt.get(emuenv.mem);
        if (opt->attr & KU_KERNEL_MEM_COMMIT_ATTR_HAS_BASE) {
            LOG_WARN("kuKernelMemCommit: baseBlock mirrors not yet implemented (baseBlock=0x{:08X} offset=0x{:08X})",
                opt->baseBlock, opt->baseOffset);
        }
    }

    const MemPerm perm = ku_prot_to_memperm(prot);
    const Address va = addr.address();

    if (perm == MemPerm::None || perm == MemPerm::ReadOnly) {
        add_protect(emuenv.mem, va, len, perm, [va, len](Address fault_addr, bool write) {
            return abort_aware_fault_callback(fault_addr, write, va, len);
        });
    } else {
        unprotect_inner(emuenv.mem, va, len);
    }

    LOG_DEBUG("kuKernelMemCommit: addr={} len={} prot=0x{:02X} -> perm={}",
        log_hex(va), len, prot, static_cast<int>(perm));
    return 0;
}

// kuKernelMemDecommit — release physical pages from a committed range.
// Uses add_protect so the fault handler catches accesses gracefully
// instead of crashing the emulator.
EXPORT(int, kuKernelMemDecommit, Ptr<void> addr, SceSize len) {
    TRACY_FUNC(kuKernelMemDecommit, addr, len);
    if (!addr || len == 0)
        return RET_ERROR(SCE_KERNEL_ERROR_INVALID_ARGUMENT);

    const Address va = addr.address();
    add_protect(emuenv.mem, va, len, MemPerm::None, [va, len](Address fault_addr, bool write) {
        return abort_aware_fault_callback(fault_addr, write, va, len);
    });

    LOG_DEBUG("kuKernelMemDecommit: addr={} len={}", log_hex(va), len);
    return 0;
}

// kuKernelRegisterExceptionHandler — register user-mode exception handler.
// On real Vita, kubridge hooks ARM exception vectors (DABT/PABT/UNDEF).
// In Vita3K, we store the handler address and the thread calls it when
// a page fault from the add_protect callback notes an abort.
EXPORT(int, kuKernelRegisterExceptionHandler, uint32_t exceptionType,
    Ptr<void> pHandler, Ptr<Ptr<void>> pOldHandler, Ptr<KuKernelExceptionHandlerOpt> pOpt) {
    TRACY_FUNC(kuKernelRegisterExceptionHandler, exceptionType, pHandler, pOldHandler, pOpt);
    if (exceptionType >= KernelState::EXCEPTION_HANDLER_MAX)
        return RET_ERROR(SCE_KERNEL_ERROR_INVALID_ARGUMENT);

    // Only DABT (type 0) is currently dispatched.
    // PABT (1) and UNDEF (2) are stored but never fired.
    if (exceptionType != 0)
        LOG_WARN("kuKernelRegisterExceptionHandler: type={} stored but not yet dispatched (only DABT=0 is)",
            exceptionType);

    const Address old_handler = emuenv.kernel.exception_handlers[exceptionType].exchange(pHandler.address());

    if (pOldHandler) {
        *pOldHandler.get(emuenv.mem) = Ptr<void>(old_handler);
    }

    LOG_INFO("kuKernelRegisterExceptionHandler: type={} handler=0x{:08X} old=0x{:08X}",
        exceptionType, pHandler.address(), old_handler);
    return 0;
}

// kuKernelReleaseExceptionHandler — unregister exception handler.
EXPORT(void, kuKernelReleaseExceptionHandler, uint32_t exceptionType) {
    TRACY_FUNC(kuKernelReleaseExceptionHandler, exceptionType);
    if (exceptionType < KernelState::EXCEPTION_HANDLER_MAX) {
        const Address old = emuenv.kernel.exception_handlers[exceptionType].exchange(0);
        LOG_INFO("kuKernelReleaseExceptionHandler: type={} old=0x{:08X}", exceptionType, old);
    }
}

// The rest of kubridge, so homebrew and Android ports built on so_loader (they import kubridge to load
// and patch the game's .so) run without the kubridge.skprx plugin installed. With the plugin installed,
// taiHEN swaps its exports for these too.

struct KuKernelAllocMemBlockOpt {
    uint32_t size;
    uint32_t field_4;
    uint32_t attr;
    uint32_t field_C; // with attr bit 0: the virtual address the block must start at
};

constexpr uint32_t KU_ALLOC_ATTR_HAS_VBASE = 0x1;

// kuKernelAllocMemBlock: a memory block, at the address the caller asks for when it asks (so_loader
// places a port's code and data at a fixed base). Guest memory is always readable, writable and
// executable here, so the block type only matters for bookkeeping
EXPORT(SceUID, kuKernelAllocMemBlock, const char *name, SceKernelMemBlockType type, SceSize size, Ptr<KuKernelAllocMemBlockOpt> pOpt) {
    TRACY_FUNC(kuKernelAllocMemBlock, type, size, pOpt);
    if (size == 0)
        return RET_ERROR(SCE_KERNEL_ERROR_INVALID_ARGUMENT);

    auto &mem = emuenv.mem;
    const auto state = emuenv.kernel.obj_store.get<SysmemState>();
    const auto guard = std::lock_guard<std::mutex>(state->mutex);

    const char *block_name = name ? name : "kubridge_block";
    const SceSize aligned = align(size, 4 * 1024);
    Address base = 0;
    if (pOpt && (pOpt.get(mem)->attr & KU_ALLOC_ATTR_HAS_VBASE) && pOpt.get(mem)->field_C) {
        base = alloc_at(mem, pOpt.get(mem)->field_C, aligned, block_name);
        if (!base)
            LOG_WARN("kuKernelAllocMemBlock: {} could not be placed at {}", block_name, log_hex(pOpt.get(mem)->field_C));
    } else {
        base = alloc(mem, aligned, block_name);
    }
    if (!base)
        return RET_ERROR(SCE_KERNEL_ERROR_NO_MEMORY);

    const SceUID uid = add_block(*state, block_name, type, base, aligned);
    LOG_INFO("kuKernelAllocMemBlock: {} at {} ({} bytes)", block_name, log_hex(base), aligned);
    return uid;
}

// kuKernelFlushCaches: the caller wrote code; drop whatever the JIT compiled from that range
EXPORT(void, kuKernelFlushCaches, Ptr<const void> ptr, SceSize len) {
    TRACY_FUNC(kuKernelFlushCaches, ptr, len);
    if (ptr && len)
        emuenv.kernel.invalidate_jit_cache(ptr.address(), len);
}

// kuKernelCpuUnrestrictedMemcpy: a copy that ignores page protection (used to patch code)
EXPORT(int, kuKernelCpuUnrestrictedMemcpy, Ptr<void> dst, Ptr<const void> src, SceSize len) {
    TRACY_FUNC(kuKernelCpuUnrestrictedMemcpy, dst, src, len);
    if (!dst || !src)
        return RET_ERROR(SCE_KERNEL_ERROR_INVALID_ARGUMENT);
    if (len == 0)
        return 0;
    if (!is_valid_addr_range(emuenv.mem, dst.address(), dst.address() + len)
        || !is_valid_addr_range(emuenv.mem, src.address(), src.address() + len))
        return RET_ERROR(SCE_KERNEL_ERROR_INVALID_ARGUMENT);
    std::memmove(dst.get(emuenv.mem), src.get(emuenv.mem), len);
    emuenv.kernel.invalidate_jit_cache(dst.address(), len);
    return 0;
}

// CPU clock requests: the phone runs at its own speed; report the Vita's top clock
EXPORT(int, kuPowerGetSysClockFrequency) {
    return 444;
}

EXPORT(int, kuPowerSetSysClockFrequency, int freq) {
    TRACY_FUNC(kuPowerSetSysClockFrequency, freq);
    return 0;
}

// Older kubridge: one abort handler = the data abort exception handler
EXPORT(int, kuKernelRegisterAbortHandler, Ptr<void> pHandler, Ptr<Ptr<void>> pOldHandler, Ptr<KuKernelExceptionHandlerOpt> pOpt) {
    TRACY_FUNC(kuKernelRegisterAbortHandler, pHandler, pOldHandler, pOpt);
    const Address old_handler = emuenv.kernel.exception_handlers[0].exchange(pHandler.address());
    if (pOldHandler)
        *pOldHandler.get(emuenv.mem) = Ptr<void>(old_handler);
    return 0;
}

EXPORT(void, kuKernelReleaseAbortHandler) {
    emuenv.kernel.exception_handlers[0].exchange(0);
}
