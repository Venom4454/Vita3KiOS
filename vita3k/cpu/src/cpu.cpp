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

#include <cpu/disasm/functions.h>
#include <cpu/functions.h>
#include <cpu/impl/dynarmic_cpu.h>
#include <cpu/impl/interface.h>
#include <cpu/state.h>
#include <mem/ptr.h>
#include <util/log.h>
#include <util/types.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

// JIT reuse. Some games start and end threads all the time (one game made almost a thousand in a
// session): each new thread built a new JIT (a few ms, serialized, and on iOS a code cache from the
// pool) and recompiled from nothing all the guest code it ran. A thread's CPU is kept when it ends and
// given to the next thread that gets the same processor number (the lowest free one, so usually the
// one just freed): same guest memory, so the code it compiled is still valid unless guest code changed
// in between, in which case its cache is cleared first.
namespace {
struct PooledCpu {
    CPUState *state = nullptr;
    uint64_t generation = 0;
};
std::mutex cpu_pool_mutex;
std::vector<PooledCpu> cpu_pool;
std::atomic<uint64_t> guest_code_generation{ 0 };
std::atomic<uint64_t> pool_epoch{ 0 };
// Each one holds a code cache from the iOS pool: few enough to leave plenty for new threads
constexpr std::size_t MAX_POOLED_CPUS = 8;
} // namespace

void note_guest_code_changed() {
    guest_code_generation.fetch_add(1, std::memory_order_relaxed);
}

static void delete_cpu_state(CPUState *state) {
    if (state && state->cpu && state->pool_epoch == pool_epoch.load()) {
        const std::lock_guard lock(cpu_pool_mutex);
        if (cpu_pool.size() < MAX_POOLED_CPUS) {
            // The thread may have compiled code before a change that happened while it ran:
            // judge by when its cache was last known good, not by when it ended
            cpu_pool.push_back({ state, state->code_generation });
            return;
        }
    }
    delete state;
}

// Threads get a fresh JIT while a game boots: reuse is for games that keep starting threads while they
// run (Ultimate Marvel vs. Capcom 3), and a game's first threads (its main thread among them) shouldn't
// start from another thread's JIT. Uncharted: Golden Abyss's main thread did, and jumped into unmapped
// memory a moment later; not proven to be the cause, but nothing is lost by starting those fresh.
static std::atomic<int64_t> reuse_allowed_after{ 0 };

static int64_t steady_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

void flush_cpu_pool() {
    reuse_allowed_after = steady_ms() + 20000;
    std::vector<PooledCpu> pooled;
    {
        const std::lock_guard lock(cpu_pool_mutex);
        // CPUs of threads that end after this are destroyed, not kept
        pool_epoch++;
        pooled.swap(cpu_pool);
    }
    for (const PooledCpu &entry : pooled)
        delete entry.state;
}

static CPUStatePtr take_pooled_cpu(bool cpu_opt, SceUID thread_id, std::size_t processor_id, MemState &mem) {
    if (reuse_allowed_after.load(std::memory_order_relaxed) == 0)
        reuse_allowed_after = steady_ms() + 20000; // the first game since launch
    if (steady_ms() < reuse_allowed_after.load(std::memory_order_relaxed))
        return CPUStatePtr();
    PooledCpu entry;
    {
        const std::lock_guard lock(cpu_pool_mutex);
        const auto it = std::ranges::find_if(cpu_pool, [&](const PooledCpu &pooled) {
            return pooled.state->mem == &mem && pooled.state->cpu_opt == cpu_opt && pooled.state->cpu->processor_id() == processor_id;
        });
        if (it == cpu_pool.end())
            return CPUStatePtr();
        entry = *it;
        cpu_pool.erase(it);
    }
    CPUStatePtr state(entry.state, delete_cpu_state);
    state->thread_id = thread_id;
    state->return_pc = 0;
    state->abort_pending = false;
    state->abort_fault_addr = 0;
    // Reset first: the reset clears halt requests, and the invalidation below is one
    state->cpu->reset_for_reuse();
    const uint64_t generation = guest_code_generation.load(std::memory_order_relaxed);
    if (entry.generation != generation)
        state->cpu->invalidate_jit_cache(0, 0xFFFFFFFF);
    state->code_generation = generation;
    state->cpu->load_context(state->initial_context);
    state->cpu->clear_exclusive();
    static std::atomic<uint64_t> reused{ 0 };
    const uint64_t count = reused.fetch_add(1, std::memory_order_relaxed) + 1;
    if (count == 1 || count % 256 == 0)
        LOG_INFO("Threads reuse the JIT of a thread that ended ({} so far): no rebuild, no recompile", count);
    return state;
}

CPUStatePtr init_cpu(bool cpu_opt, SceUID thread_id, std::size_t processor_id, MemState &mem) {
    if (CPUStatePtr reused = take_pooled_cpu(cpu_opt, thread_id, processor_id, mem))
        return reused;

    CPUStatePtr state(new CPUState(), delete_cpu_state);
    state->mem = &mem;
    state->thread_id = thread_id;
    state->cpu_opt = cpu_opt;
    state->pool_epoch = pool_epoch.load();
    state->code_generation = guest_code_generation.load(std::memory_order_relaxed);

    if (!init(state->disasm)) {
        return CPUStatePtr();
    }

    try {
        state->cpu = std::make_unique<DynarmicCPU>(state.get(), processor_id, cpu_opt);
    } catch (const std::exception &) {
        // No code cache left (iOS): the JITs kept for reuse hold some, give them back and try again
        flush_cpu_pool();
        state->cpu = std::make_unique<DynarmicCPU>(state.get(), processor_id, cpu_opt);
    }
    state->initial_context = state->cpu->save_context();

    return state;
}

CPUStop run(CPUState &state) {
    return state.cpu->run();
}

CPUStop step(CPUState &state) {
    return state.cpu->step();
}

void place_call(CPUState &state, Address fn, std::initializer_list<uint32_t> args) {
    write_pc(state, fn);
    write_lr(state, state.return_pc);
    Address sp = read_sp(state);
    for (size_t i = 0; i < std::min<size_t>(args.size(), 4); i++)
        write_reg(state, i, args.begin()[i]);
    if (args.size() > 4) {
        // the ARM calling convention keeps the stack 16-byte aligned at a call (upstream f6b86e2d)
        constexpr size_t stack_alignment = 16;
        const size_t stack_args_size = sizeof(uint32_t) * (args.size() - 4);
        sp -= static_cast<uint32_t>((stack_args_size + stack_alignment - 1) & ~(stack_alignment - 1));
        std::ranges::copy(args.begin() + 4, args.end(), Ptr<uint32_t>(sp).get(*state.mem));
    }
    write_sp(state, sp);
}

void stop(CPUState &state) {
    state.cpu->stop();
}

uint32_t read_reg(CPUState &state, size_t index) {
    return state.cpu->get_reg(index);
}

float read_float_reg(CPUState &state, size_t index) {
    return state.cpu->get_float_reg(index);
}

void write_float_reg(CPUState &state, size_t index, float value) {
    state.cpu->set_float_reg(index, value);
}

void write_fpscr(CPUState &state, uint32_t value) {
    state.cpu->set_fpscr(value);
}

void write_cpsr(CPUState &state, uint32_t value) {
    state.cpu->set_cpsr(value);
}

uint32_t read_sp(CPUState &state) {
    return state.cpu->get_sp();
}

uint32_t read_pc(CPUState &state) {
    return state.cpu->get_pc();
}

uint32_t read_lr(CPUState &state) {
    return state.cpu->get_lr();
}

uint32_t read_fpscr(CPUState &state) {
    return state.cpu->get_fpscr();
}

uint32_t read_cpsr(CPUState &state) {
    return state.cpu->get_cpsr();
}

uint32_t read_tpidruro(CPUState &state) {
    return state.cpu->get_tpidruro();
}

uint32_t read_tpidrurw(CPUState &state) {
    return state.cpu->get_tpidrurw();
}

void write_reg(CPUState &state, size_t index, uint32_t value) {
    state.cpu->set_reg(index, value);
}

void write_sp(CPUState &state, uint32_t value) {
    state.cpu->set_sp(value);
}

void write_pc(CPUState &state, uint32_t value) {
    state.cpu->set_pc(value);
}

void write_lr(CPUState &state, uint32_t value) {
    state.cpu->set_lr(value);
}

void write_tpidruro(CPUState &state, uint32_t value) {
    state.cpu->set_tpidruro(value);
}

void write_tpidrurw(CPUState &state, uint32_t value) {
    state.cpu->set_tpidrurw(value);
}

bool hit_breakpoint(CPUState &state) {
    return state.cpu->hit_breakpoint();
}

void trigger_breakpoint(CPUState &state) {
    state.cpu->trigger_breakpoint();
}

void set_log_code(CPUState &state, bool log) {
    state.cpu->set_log_code(log);
}

void set_log_mem(CPUState &state, bool log) {
    state.cpu->set_log_mem(log);
}

bool get_log_mem(CPUState &state) {
    return state.cpu->get_log_mem();
}

void clear_exclusive(CPUState &state) {
    state.cpu->clear_exclusive();
}

std::size_t get_processor_id(CPUState &state) {
    return state.cpu->processor_id();
}

void invalidate_jit_cache(CPUState &state, Address start, size_t length) {
    note_guest_code_changed();
    state.cpu->invalidate_jit_cache(start, length);
}

std::string disassemble(CPUState &state, uint64_t at, bool thumb, uint16_t *insn_size) {
    MemState &mem = *state.mem;
    const uint8_t *const code = Ptr<const uint8_t>(static_cast<Address>(at)).get(mem);
    const size_t buffer_size = GiB(4) - at;
    return disassemble(state.disasm, code, buffer_size, at, thumb, insn_size);
}

std::string disassemble(CPUState &state, uint64_t at, uint16_t *insn_size) {
    const bool thumb = state.cpu->is_thumb_mode();
    return disassemble(state, at, thumb, insn_size);
}

CPUContext save_context(CPUState &state) {
    return state.cpu->save_context();
}

void load_context(CPUState &state, const CPUContext &ctx) {
    state.cpu->load_context(ctx);
}

uint32_t stack_alloc(CPUState &state, size_t size) {
    const uint32_t new_sp = read_sp(state) - size;
    write_sp(state, new_sp);
    return new_sp;
}

void stack_free(CPUState &state, size_t size) {
    write_sp(state, read_sp(state) + size);
}

static thread_local CPUState *current_cpu_state = nullptr;

void set_current_cpu_state(CPUState *state) {
    current_cpu_state = state;
}

CPUState *get_current_cpu_state() {
    return current_cpu_state;
}
