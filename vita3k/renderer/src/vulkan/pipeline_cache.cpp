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

#include <renderer/vulkan/pipeline_cache.h>

#include <renderer/vulkan/functions.h>

#include <renderer/vulkan/gxm_to_vulkan.h>
#include <renderer/vulkan/state.h>
#include <renderer/vulkan/types.h>

#include <gxm/functions.h>
#include <gxm/types.h>
#include <renderer/shaders.h>
#include <shader/spirv_recompiler.h>

#include <util/fs.h>
#include <util/log.h>

#include <SDL3/SDL_cpuinfo.h>

#if defined(VITA3K_PLATFORM_IOS)
#include <pthread.h>
#include <sys/qos.h>
#include <util/app_activity.h>
#include <util/thermal.h>
#endif

// don't use the dispatch version, because we always hash a small amount
// with a known size
#define XXH_INLINE_ALL
#include <xxhash.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <optional>
#include <thread>

namespace renderer::vulkan {

// Marks a pipeline the driver refused to build (on iOS: Metal could not compile the converted shader).
// Its draws are skipped instead of retrying the compile on every draw.
static vk::Pipeline failed_pipeline() {
    return std::bit_cast<vk::Pipeline, uint64_t>(~1ULL);
}

// Size of the record containing what is needed for the pipeline construction (what is after is dynamic state)
constexpr size_t record_pipeline_len = offsetof(GxmRecordState, vertex_streams);

// structure containing everything needed to compile a pipeline
struct CompileRequest {
    // iterator to the pipeline location
    vk::Pipeline *pipeline;

    // this is everything we need to compile the shader on another thread (as the original data will change)
    SceGxmPrimitiveType type;
    vk::RenderPass render_pass;
    SceGxmVertexProgram *vertex_program_gxm;
    SceGxmFragmentProgram *fragment_program_gxm;
    shader::Hints hints;

    // the content of the record useful for the pipeline creation
    alignas(8) uint8_t record_data[record_pipeline_len];

    const GxmRecordState *get_record() {
        // note: this object is only half defined, but we are only looking at the part that's defined
        return reinterpret_cast<const GxmRecordState *>(record_data);
    }
};

PipelineCache::PipelineCache(VKState &state)
    : state(state)
    , pipeline_compile_queue_token(pipeline_compile_queue) {
}

void PipelineCache::init(bool support_rasterized_order_access) {
    vk::PipelineCacheCreateInfo pipeline_info{};
    pipeline_cache = state.device.createPipelineCache(pipeline_info);

    // the layout for uniforms buffer can be made here as it will always be the same
    {
        std::array<vk::DescriptorSetLayoutBinding, 4> layout_bindings;
        // Our vertex uniform (GXMRenderVertUniformBlock)
        layout_bindings[0] = vk::DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = vk::DescriptorType::eUniformBufferDynamic,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eVertex,
        };
        // Our fragment uniform (GXMRenderFragUniformBlock)
        layout_bindings[1] = vk::DescriptorSetLayoutBinding{
            .binding = 1,
            .descriptorType = vk::DescriptorType::eUniformBufferDynamic,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eFragment,
        };
        // GXM vertex uniform (if no memory mapping)
        layout_bindings[2] = vk::DescriptorSetLayoutBinding{
            .binding = 2,
            .descriptorType = vk::DescriptorType::eStorageBufferDynamic,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eVertex,
        };
        // GXM Fragment uniform (if no memory mapping)
        layout_bindings[3] = vk::DescriptorSetLayoutBinding{
            .binding = 3,
            .descriptorType = vk::DescriptorType::eStorageBufferDynamic,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eFragment,
        };

        vk::DescriptorSetLayoutCreateInfo descriptor_info{
            .bindingCount = state.features.enable_memory_mapping ? 2U : 4U,
            .pBindings = layout_bindings.data()
        };
        uniforms_layout = state.device.createDescriptorSetLayout(descriptor_info);
    }

    {
        // layout for the mask, color attachment as input, being an input attachment or a storage image
        // depending on whether or not we are using shader interlock
        std::array<vk::DescriptorSetLayoutBinding, 3> layout_binding;
        const vk::DescriptorType intput_image_descriptor = state.features.support_shader_interlock
            ? vk::DescriptorType::eStorageImage
            : vk::DescriptorType::eInputAttachment;
        layout_binding[0] = vk::DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = intput_image_descriptor,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eFragment
        };
        layout_binding[2] = vk::DescriptorSetLayoutBinding{
            .binding = 2,
            .descriptorType = vk::DescriptorType::eInputAttachment,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eFragment
        };
        layout_binding[1] = vk::DescriptorSetLayoutBinding{
            .binding = 1,
            .descriptorType = vk::DescriptorType::eStorageImage,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eFragment
        };

        vk::DescriptorSetLayoutCreateInfo descriptor_info{
            .bindingCount = state.features.use_mask_bit ? (state.features.support_shader_interlock ? 3U : 2U) : 1U,
            .pBindings = layout_binding.data()
        };
        attachments_layout = state.device.createDescriptorSetLayout(descriptor_info);
    }

    {
        // texture layout

        // empty descriptor
        {
            vk::DescriptorSetLayoutCreateInfo empty_info{};
            vertex_textures_layout[0] = state.device.createDescriptorSetLayout(empty_info);
            fragment_textures_layout[0] = vertex_textures_layout[0];
        }

        // first vertex
        std::array<vk::DescriptorSetLayoutBinding, 16> layout_bindings;
        for (uint32_t i = 0; i < 16; i++) {
            layout_bindings[i] = {
                .binding = i,
                .descriptorType = vk::DescriptorType::eCombinedImageSampler,
                .descriptorCount = 1,
                .stageFlags = vk::ShaderStageFlagBits::eVertex
            };
        }
        for (uint32_t i = 1; i <= 16; i++) {
            vk::DescriptorSetLayoutCreateInfo descriptor_info{
                .bindingCount = i,
                .pBindings = layout_bindings.data()
            };
            vertex_textures_layout[i] = state.device.createDescriptorSetLayout(descriptor_info);
        }

        // then fragment
        for (uint32_t i = 0; i < 16; i++) {
            layout_bindings[i].stageFlags = vk::ShaderStageFlagBits::eFragment;
        }
        for (uint32_t i = 1; i <= 16; i++) {
            vk::DescriptorSetLayoutCreateInfo descriptor_info{
                .bindingCount = i,
                .pBindings = layout_bindings.data()
            };
            fragment_textures_layout[i] = state.device.createDescriptorSetLayout(descriptor_info);
        }
    }

    // compute all possible pipeline layouts
    for (uint32_t vert_texture_count = 0; vert_texture_count <= 16; vert_texture_count++) {
        for (uint32_t frag_texture_count = 0; frag_texture_count <= 16; frag_texture_count++) {
            vk::PipelineLayoutCreateInfo layout_info{};
            vk::DescriptorSetLayout set_layouts[] = { uniforms_layout, attachments_layout, vertex_textures_layout[vert_texture_count], fragment_textures_layout[frag_texture_count] };
            layout_info.setSetLayouts(set_layouts);
            pipeline_layouts[vert_texture_count][frag_texture_count] = state.device.createPipelineLayout(layout_info);
        }
    }

    {
        // look for rgb vertex attribute support
        // we need to look at each format because it is not the same for all usual 3-component formats (checked on AMD Radeon HD 7800)
        // no need to test for 32-bit types, they are always supported
        vk::Format formats[] = {
            vk::Format::eR16G16B16Unorm, vk::Format::eR16G16B16Snorm,
            vk::Format::eR16G16B16Uscaled, vk::Format::eR16G16B16Sscaled,
            vk::Format::eR16G16B16Uint, vk::Format::eR16G16B16Sint,
            vk::Format::eR16G16B16Sfloat,
            vk::Format::eR8G8B8Unorm, vk::Format::eR8G8B8Snorm,
            vk::Format::eR8G8B8Uscaled, vk::Format::eR8G8B8Sscaled,
            vk::Format::eR8G8B8Uint, vk::Format::eR8G8B8Sint
        };
        for (auto fmt : formats) {
            vk::FormatProperties rgb_property = state.physical_device.getFormatProperties(fmt);
            if (!(rgb_property.bufferFeatures & vk::FormatFeatureFlagBits::eVertexBuffer)) {
                unsupported_rgb_vertex_attribute_formats.emplace(fmt);
            }
        }

        // same for scaled formats
        const vk::FormatProperties scaled_property = state.physical_device.getFormatProperties(vk::Format::eR8G8B8A8Uscaled);
        support_scaled_vertex_attribute = static_cast<bool>(scaled_property.bufferFeatures & vk::FormatFeatureFlagBits::eVertexBuffer);
        state.features.support_scaled_attribute_formats = support_scaled_vertex_attribute;

        // handle interactions between these 2 properties, the scaled support will be applied before the 3-component support
        if (!support_scaled_vertex_attribute) {
            vk::Format scaled_fmt[] = { vk::Format::eR16G16B16Uscaled, vk::Format::eR16G16B16Sscaled, vk::Format::eR8G8B8Uscaled, vk::Format::eR8G8B8Sscaled };
            for (auto fmt : scaled_fmt)
                unsupported_rgb_vertex_attribute_formats.erase(fmt);
        }

        state.features.support_rgb_attributes = unsupported_rgb_vertex_attribute_formats.empty();
    }

    support_coherent_framebuffer_fetch = support_rasterized_order_access;

    const int nb_logical_threads = SDL_GetNumLogicalCPUCores();
    // took this from RPCS3 (slightly modified)
    if (nb_logical_threads > 12)
        nb_worker_threads = 6;
    else if (nb_logical_threads > 8)
        nb_worker_threads = 4;
    else if (nb_logical_threads >= 8)
        nb_worker_threads = 3;
    else if (nb_logical_threads >= 6)
        nb_worker_threads = 2;
    else
        nb_worker_threads = 1;
#if defined(VITA3K_PLATFORM_IOS)
    // Metal compiles pipelines on its own threads too; four workers let shader-heavy games (Madden
    // NFL 13 compiles 200+ pipelines in its first match) finish and show their objects much sooner
    nb_worker_threads = std::max(nb_worker_threads, 4);
#endif

    abandon_compiles.store(false, std::memory_order_release);

    if (use_async_compilation) {
        // we could not initialize the worker threads previously
        use_async_compilation = false;
        set_async_compilation(true);
    }
}

void PipelineCache::set_async_compilation(bool enable) {
    if (enable == use_async_compilation)
        return;

    use_async_compilation = enable;
    if (nb_worker_threads == 0)
        // not ingame yet
        return;

    if (enable) {
        LOG_INFO("Enabling asynchronous pipeline compilation with {} threads", nb_worker_threads);
        worker_threads.reserve(nb_worker_threads);
        for (int i = 0; i < nb_worker_threads; i++) {
            worker_threads.emplace_back(&PipelineCache::compiler_thread, this, std::ref(*state.mem));
        }
    } else {
        LOG_INFO("Asynchronous pipeline compilation is now disabled");

        for (size_t i = 0; i < worker_threads.size(); i++)
            // if a thread receives nullptr, it exits
            pipeline_compile_queue.enqueue(nullptr);

        for (auto &thread : worker_threads) {
            if (thread.joinable())
                thread.join();
        }
        worker_threads.clear();
    }
}

// magic number put at the beginning of the pipeline cache file
constexpr uint32_t pipeline_cache_magic = 0xBEEF4321;

void PipelineCache::read_pipeline_cache() {
    const std::string pipeline_cache_name = fmt::format("pipeline-cache-vk{}.dat", shader::CURRENT_VERSION);
    const fs::path path = state.shaders_path / pipeline_cache_name;

    std::ifstream pipeline_cache_file(path, std::ios::in | std::ios::binary);
    if (!pipeline_cache_file.is_open())
        return;

    LOG_INFO("Found pipeline cache, reading...");

    pipeline_cache_file.seekg(0, std::ifstream::end);
    size_t pipeline_size = pipeline_cache_file.tellg();
    pipeline_cache_file.seekg(0);

    if (pipeline_size < sizeof(uint32_t) + sizeof(size_t))
        return;

    // read the hashes
    auto read_integer = [&]<typename T>(T &val) {
        pipeline_cache_file.read(reinterpret_cast<char *>(&val), sizeof(T));
    };
    uint32_t magic_number;
    read_integer(magic_number);
    size_t nb_hashes;
    read_integer(nb_hashes);
    // safety check
    size_t hashes_size = sizeof(magic_number) + sizeof(nb_hashes) + nb_hashes * sizeof(uint64_t);
    if (magic_number != pipeline_cache_magic || pipeline_size < hashes_size) {
        LOG_WARN("Pipeline cache is corrupted, ignoring it.");
        pipeline_cache_file.close();
        return;
    }
    pipeline_size -= hashes_size;

    // insert hashes with null pipeline
    for (size_t i = 0; i < nb_hashes; i++) {
        uint64_t hash;
        read_integer(hash);
        pipelines[hash] = nullptr;
    }

    std::vector<char> pipeline_data(pipeline_size);
    pipeline_cache_file.read(pipeline_data.data(), pipeline_size);
    pipeline_cache_file.close();

    // Turned back into a driver cache on its own thread (see loaded_cache): the game starts at once
    if (cache_loader.joinable())
        cache_loader.join();
    if (loaded_cache_ready.exchange(false))
        state.device.destroyPipelineCache(loaded_cache);
    loaded_cache = nullptr;
    cache_loader = std::thread([this, path, pipeline_data = std::move(pipeline_data)]() {
        const auto start = std::chrono::steady_clock::now();
        vk::PipelineCacheCreateInfo cache_info{
            .initialDataSize = pipeline_data.size(),
            .pInitialData = pipeline_data.data()
        };
        try {
            loaded_cache = state.device.createPipelineCache(cache_info);
        } catch (const vk::SystemError &e) {
            // A damaged cache file (for example saved after the GPU failed) must never stop the game:
            // drop it, the pipelines get rebuilt (into the empty cache, which is the one saved then)
            LOG_WARN("Pipeline cache could not be loaded ({}), deleting it and starting fresh", e.what());
            std::error_code ec;
            fs::remove(path, ec);
            return;
        }
        loaded_cache_ready.store(true, std::memory_order_release);
        LOG_INFO("Pipeline cache read and loaded in the background ({} ms, {} MiB)",
            std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count(),
            pipeline_data.size() / (1024 * 1024));
    });
}

void PipelineCache::save_pipeline_cache(bool in_background) {
    // Snapshot what the save needs on the calling (renderer) thread: the shader hashes and the
    // pipeline hashes. The slow part (asking the driver for its cache data and writing the file,
    // 10-30 ms on iOS) can then run on a thread of its own instead of hitching a frame.
    std::vector<ShadersHash> shader_cache_copy;
    {
        std::lock_guard<std::mutex> guard(shaders_mutex);
        shader_cache_copy = state.shaders_cache_hashs;
    }
    std::vector<uint64_t> pipeline_hashes;
    pipeline_hashes.reserve(pipelines.size());
    for (auto &[hash, _] : pipelines)
        pipeline_hashes.push_back(hash);

    auto work = [this, shader_cache_copy = std::move(shader_cache_copy), pipeline_hashes = std::move(pipeline_hashes)]() mutable {
        renderer::save_shaders_cache_hashs(state, shader_cache_copy);

        // After the GPU failed (device lost) the driver's cache data can be garbage: keep the last good file
        if (device_lost_count() > 0) {
            LOG_WARN("Not saving the pipeline cache: the GPU failed during this session");
            return;
        }

        std::vector<uint8_t> pipeline_data;
        try {
            pipeline_data = state.device.getPipelineCacheData(active_cache());
        } catch (const vk::SystemError &e) {
            LOG_WARN("Not saving the pipeline cache: {}", e.what());
            return;
        }
        if (pipeline_data.empty())
            // No pipeline was created
            return;

        const std::string pipeline_cache_name = fmt::format("pipeline-cache-vk{}.dat", shader::CURRENT_VERSION);
        const fs::path path = state.shaders_path / pipeline_cache_name;

        // Written to a temporary file first and then moved over the old one, so a crash or the app
        // being closed mid-write never leaves a half-written cache behind
        fs::path tmp_path = path;
        tmp_path += ".tmp";
        std::ofstream pipeline_cache_file(tmp_path, std::ios::out | std::ios::binary | std::ios::trunc);
        if (!pipeline_cache_file.is_open())
            return;

        LOG_INFO("Saving pipeline cache...");

        // first save the hashes of all pipelines
        auto write_integer = [&]<typename T>(T val) {
            pipeline_cache_file.write(reinterpret_cast<const char *>(&val), sizeof(T));
        };
        write_integer(pipeline_cache_magic);
        write_integer(pipeline_hashes.size());
        for (const uint64_t hash : pipeline_hashes)
            write_integer(hash);

        // then save the cache
        pipeline_cache_file.write(reinterpret_cast<const char *>(pipeline_data.data()), pipeline_data.size());
        pipeline_cache_file.close();
        std::error_code ec;
        if (pipeline_cache_file)
            fs::rename(tmp_path, path, ec);
        if (!pipeline_cache_file || ec) {
            LOG_WARN("Pipeline cache could not be saved");
            fs::remove(tmp_path, ec);
            return;
        }
        LOG_INFO("Pipeline cache saved");
    };

    if (in_background) {
        if (cache_saving.load(std::memory_order_acquire)) {
            // the previous save is still running: try again a little later
            const auto time_s = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
            next_pipeline_cache_save = time_s + 2;
            return;
        }
        if (cache_save_thread.joinable())
            cache_save_thread.join();
        cache_saving.store(true, std::memory_order_release);
        cache_save_thread = std::thread([this, work = std::move(work)]() mutable {
#if defined(VITA3K_PLATFORM_IOS)
            pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#endif
            work();
            cache_saving.store(false, std::memory_order_release);
        });
        return;
    }

    wait_for_cache_save();
    work();
}

void PipelineCache::wait_for_cache_save() {
    if (cache_save_thread.joinable())
        cache_save_thread.join();
}

void PipelineCache::cleanup() {
    // a background save still reads the pipeline cache
    wait_for_cache_save();

    // stop threads, dropping whatever pipelines are still waiting to be compiled
    abandon_compiles.store(true, std::memory_order_release);
    if (use_async_compilation)
        set_async_compilation(false);

    // markers are not pipelines: one still "compiling" when the workers stopped, or one that failed
    const vk::Pipeline still_compiling = std::bit_cast<vk::Pipeline, uint64_t>(~0ULL);
    for (auto &[hash, pipeline] : pipelines) {
        if (pipeline && pipeline != failed_pipeline() && pipeline != still_compiling)
            state.device.destroy(pipeline);
    }
    pipelines.clear();

    {
        std::lock_guard<std::mutex> guard(shaders_mutex);
        for (auto &[hash, shader] : shaders)
            state.device.destroy(shader);
        shaders.clear();
        for (auto &[hash, shader] : masked_fetch_shaders)
            state.device.destroy(shader);
        masked_fetch_shaders.clear();
        state.device.destroy(mask_test_shader);
        mask_test_shader = nullptr;
    }

    for (int i = 0; i < 2; i++)
        for (int j = 0; j < 2; j++)
            for (int k = 0; k < 2; k++) {
                for (auto &[fmt, pass] : render_passes[i][j][k])
                    state.device.destroy(pass);
                render_passes[i][j][k].clear();
            }

    for (auto &[fmt, pass] : shader_interlock_pass)
        state.device.destroy(pass);
    shader_interlock_pass.clear();
    state.device.destroy(mask_render_pass);
    mask_render_pass = nullptr;

    for (int i = 0; i < 17; i++)
        for (int j = 0; j < 17; j++) {
            state.device.destroy(pipeline_layouts[i][j]);
            pipeline_layouts[i][j] = nullptr;
        }

    state.device.destroy(uniforms_layout);
    uniforms_layout = nullptr;
    state.device.destroy(attachments_layout);
    attachments_layout = nullptr;

    state.device.destroy(vertex_textures_layout[0]);
    vertex_textures_layout[0] = nullptr;
    fragment_textures_layout[0] = nullptr;

    for (int i = 1; i <= 16; i++) {
        state.device.destroy(vertex_textures_layout[i]);
        vertex_textures_layout[i] = nullptr;
        state.device.destroy(fragment_textures_layout[i]);
        fragment_textures_layout[i] = nullptr;
    }

    if (cache_loader.joinable())
        cache_loader.join();
    if (loaded_cache_ready.exchange(false))
        state.device.destroy(loaded_cache);
    loaded_cache = nullptr;
    state.device.destroy(pipeline_cache);
    pipeline_cache = nullptr;

    next_pipeline_cache_save = std::numeric_limits<uint64_t>::max();
    nb_worker_threads = 0;
}

// Vulkan structs used to specify a specialization constant
// Also, booleans in SPIRV are 32bit wide
static const vk::SpecializationMapEntry srgb_entry = {
    .constantID = shader::GAMMA_CORRECTION_SPECIALIZATION_ID,
    .offset = 0,
    .size = sizeof(uint32_t)
};

static const uint32_t srgb_entry_true = vk::True;
static const uint32_t srgb_entry_false = vk::False;

static const vk::SpecializationInfo srgb_info_true = {
    .mapEntryCount = 1,
    .pMapEntries = &srgb_entry,
    .dataSize = sizeof(uint32_t),
    .pData = &srgb_entry_true
};

static const vk::SpecializationInfo srgb_info_false = {
    .mapEntryCount = 1,
    .pMapEntries = &srgb_entry,
    .dataSize = sizeof(uint32_t),
    .pData = &srgb_entry_false
};

static bool manifest_lists(VKState &state, std::mutex &shaders_mutex, const Sha256Hash &hash) {
    std::lock_guard<std::mutex> guard(shaders_mutex);
    return std::ranges::any_of(state.shaders_cache_hashs, [&hash](const ShadersHash &entry) {
        return entry.vert == hash || entry.frag == hash;
    });
}

vk::PipelineShaderStageCreateInfo PipelineCache::retrieve_shader(const SceGxmProgram *program, const Sha256Hash &program_hash, bool is_vertex, bool maskupdate, MemState &mem, const shader::Hints &hints, bool is_srgb) {
    const vk::ShaderModule shader_compiling = std::bit_cast<vk::ShaderModule>(~0ULL);
    const bool masked_fetch = !is_vertex && hints.masked_framebuffer_fetch;
    // A vertex program that writes memory comes in two variants (without the writes, with only them);
    // each has its own key and cache file, and neither goes in the precompile list
    const bool split_stores = is_vertex && shader::splits_vertex_stores(*program, state.features);
    Sha256Hash hash = program_hash;
    if (split_stores)
        hash[7] ^= hints.vertex_store_pass ? 0x5E : 0x4E;

    const vk::SpecializationInfo *spec_info = nullptr;
    if (!is_vertex && !masked_fetch && state.features.should_use_shader_interlock() && program->is_frag_color_used()) {
        // if the specialization constant is used in the shader
        spec_info = is_srgb ? &srgb_info_true : &srgb_info_false;
    }

    vk::ShaderModule *shader_module;
    {
        // look if it is in the cache
        std::unique_lock<std::mutex> lock(shaders_mutex);
        auto &cache = masked_fetch ? masked_fetch_shaders : shaders;
        shader_module = &cache.insert({ hash, nullptr }).first->second;
        if (*shader_module == shader_compiling) {
            // another thread is compiling the same exact shader at the same time
            // it's no use re-compiling it, so just wait for the other thread being done
            lock.unlock();

            // we shouldn't need atomics and the compiler shouldn't be able to optimize this
            while (*shader_module == shader_compiling)
                std::this_thread::yield();
        }

        if (*shader_module == nullptr)
            // now mark the shader as compiling so that other threads accessing it won't try to compile it a second time
            *shader_module = shader_compiling;
    }

    const bool listed = manifest_lists(state, shaders_mutex, program_hash);

    if (*shader_module == shader_compiling && !masked_fetch && !split_stores && listed) {
        precompile_shader(hash, false);
    }

    if (*shader_module != shader_compiling) {
        vk::PipelineShaderStageCreateInfo shader_stage_info{
            .stage = is_vertex ? vk::ShaderStageFlagBits::eVertex : vk::ShaderStageFlagBits::eFragment,
            .module = *shader_module,
            .pName = is_vertex ? "main_vs" : "main_fs",
            .pSpecializationInfo = spec_info,
        };
        return shader_stage_info;
    }

    const std::string hash_text = hex_string(hash);

    LOG_INFO("Generating vulkan spv shader {}", hash_text);
    const std::string shader_version = fmt::format("vk{}", shader::CURRENT_VERSION);

    auto features = state.features;
    if (masked_fetch)
        features.direct_fragcolor = true;
    std::string version = masked_fetch ? shader_version + "-masked-fetch1" : shader_version;
    if (split_stores)
        version += hints.vertex_store_pass ? "-vstore" : "-vnostore";
    shader::usse::SpirvCode source = load_spirv_shader(*program, features, true, hints, maskupdate, state.shaders_path, state.shaders_log_path, version, listed);

    vk::ShaderModuleCreateInfo shader_info{
        .codeSize = sizeof(uint32_t) * source.size(),
        .pCode = source.data()
    };

    *shader_module = state.device.createShaderModule(shader_info);
    if (!masked_fetch && !split_stores) {
        std::lock_guard<std::mutex> guard(shaders_mutex);
        // Save shader cache hashes
        // vertex and fragment shaders are not linked together so no need to associate them
        Sha256Hash empty_hash{};
        if (is_vertex) {
            state.shaders_cache_hashs.push_back({ hash, empty_hash });
        } else {
            state.shaders_cache_hashs.push_back({ empty_hash, hash });
        }
    }

    vk::PipelineShaderStageCreateInfo shader_stage_info{
        .stage = is_vertex ? vk::ShaderStageFlagBits::eVertex : vk::ShaderStageFlagBits::eFragment,
        .module = *shader_module,
        .pName = is_vertex ? "main_vs" : "main_fs",
        .pSpecializationInfo = spec_info,
    };

    return shader_stage_info;
}

vk::RenderPass PipelineCache::retrieve_mask_render_pass() {
    if (mask_render_pass)
        return mask_render_pass;

    const vk::AttachmentDescription attachment{
        .format = vk::Format::eR8G8B8A8Unorm,
        .samples = vk::SampleCountFlagBits::e1,
        .loadOp = vk::AttachmentLoadOp::eLoad,
        .storeOp = vk::AttachmentStoreOp::eStore,
        .initialLayout = vk::ImageLayout::eGeneral,
        .finalLayout = vk::ImageLayout::eGeneral
    };
    const vk::AttachmentReference color_ref{ 0, vk::ImageLayout::eGeneral };
    vk::SubpassDescription subpass{
        .pipelineBindPoint = vk::PipelineBindPoint::eGraphics
    };
    subpass.setColorAttachments(color_ref);

    const std::array<vk::SubpassDependency, 2> dependencies{ { { .srcSubpass = VK_SUBPASS_EXTERNAL,
                                                                   .dstSubpass = 0,
                                                                   .srcStageMask = vk::PipelineStageFlagBits::eFragmentShader | vk::PipelineStageFlagBits::eColorAttachmentOutput,
                                                                   .dstStageMask = vk::PipelineStageFlagBits::eColorAttachmentOutput,
                                                                   .srcAccessMask = vk::AccessFlagBits::eShaderRead | vk::AccessFlagBits::eColorAttachmentWrite,
                                                                   .dstAccessMask = vk::AccessFlagBits::eColorAttachmentRead | vk::AccessFlagBits::eColorAttachmentWrite },
        { .srcSubpass = 0,
            .dstSubpass = VK_SUBPASS_EXTERNAL,
            .srcStageMask = vk::PipelineStageFlagBits::eColorAttachmentOutput,
            .dstStageMask = vk::PipelineStageFlagBits::eFragmentShader | vk::PipelineStageFlagBits::eColorAttachmentOutput,
            .srcAccessMask = vk::AccessFlagBits::eColorAttachmentWrite,
            .dstAccessMask = vk::AccessFlagBits::eShaderRead | vk::AccessFlagBits::eColorAttachmentRead | vk::AccessFlagBits::eColorAttachmentWrite } } };
    vk::RenderPassCreateInfo pass_info;
    pass_info.setAttachments(attachment);
    pass_info.setSubpasses(subpass);
    pass_info.setDependencies(dependencies);
    mask_render_pass = state.device.createRenderPass(pass_info);
    return mask_render_pass;
}

vk::RenderPass PipelineCache::retrieve_render_pass(vk::Format format, bool force_load, bool force_store, bool is_color_transient, bool no_color) {
    auto &render_passes_map = no_color ? shader_interlock_pass : render_passes[is_color_transient][force_load][force_store];

    auto it = render_passes_map.find(format);

    if (it != render_passes_map.end())
        return it->second;

    // create a new render pass for this format

    vk::AttachmentReference color_ref{
        .attachment = 0,
        .layout = vk::ImageLayout::eGeneral
    };
    vk::AttachmentReference ds_ref{
        .attachment = no_color ? 0U : 1U,
        .layout = vk::ImageLayout::eDepthStencilAttachmentOptimal
    };
    vk::SubpassDescription subpass{
        .pipelineBindPoint = vk::PipelineBindPoint::eGraphics
    };

    subpass.setPDepthStencilAttachment(&ds_ref);
    if (!no_color) {
        if (support_coherent_framebuffer_fetch)
            subpass.flags = vk::SubpassDescriptionFlagBits::eRasterizationOrderAttachmentColorAccessEXT;

        subpass.setColorAttachments(color_ref);
        subpass.setInputAttachments(color_ref);
    }

    vk::AttachmentDescription color_attachment{
        .format = format,
        .samples = vk::SampleCountFlagBits::e1,
        .loadOp = is_color_transient ? vk::AttachmentLoadOp::eDontCare : vk::AttachmentLoadOp::eLoad,
        .storeOp = is_color_transient ? vk::AttachmentStoreOp::eDontCare : vk::AttachmentStoreOp::eStore,
        .initialLayout = is_color_transient ? vk::ImageLayout::eUndefined : vk::ImageLayout::eGeneral,
        .finalLayout = vk::ImageLayout::eGeneral
    };

    vk::AttachmentLoadOp load_op = force_load ? vk::AttachmentLoadOp::eLoad : vk::AttachmentLoadOp::eClear;
    vk::AttachmentStoreOp store_op = force_store ? vk::AttachmentStoreOp::eStore : vk::AttachmentStoreOp::eDontCare;
    vk::AttachmentDescription ds_attachment{
        .format = state.deep_stencil_use,
        .samples = vk::SampleCountFlagBits::e1,
        .loadOp = load_op,
        .storeOp = store_op,
        .stencilLoadOp = load_op,
        .stencilStoreOp = store_op,
        .initialLayout = force_load ? vk::ImageLayout::eDepthStencilReadOnlyOptimal : vk::ImageLayout::eUndefined,
        .finalLayout = vk::ImageLayout::eDepthStencilReadOnlyOptimal
    };

    std::array<vk::SubpassDependency, 5> dependencies;

    // external dependency
    // we want the previous render pass to be done when we reach the fragment stage / stencil*depth testing
    dependencies[0] = {
        .srcSubpass = VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk::PipelineStageFlagBits::eColorAttachmentOutput | vk::PipelineStageFlagBits::eEarlyFragmentTests | vk::PipelineStageFlagBits::eLateFragmentTests,
        .dstStageMask = vk::PipelineStageFlagBits::eColorAttachmentOutput | vk::PipelineStageFlagBits::eEarlyFragmentTests | vk::PipelineStageFlagBits::eLateFragmentTests,
        .srcAccessMask = vk::AccessFlagBits::eColorAttachmentWrite | vk::AccessFlagBits::eDepthStencilAttachmentWrite,
        .dstAccessMask = vk::AccessFlagBits::eColorAttachmentRead | vk::AccessFlagBits::eColorAttachmentWrite
            | vk::AccessFlagBits::eDepthStencilAttachmentRead | vk::AccessFlagBits::eDepthStencilAttachmentWrite
    };

    // if an attachment is sampled from, we want it to be done before the next render pass fragment shader
    dependencies[1] = {
        .srcSubpass = VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk::PipelineStageFlagBits::eFragmentShader,
        .dstStageMask = vk::PipelineStageFlagBits::eColorAttachmentOutput | vk::PipelineStageFlagBits::eEarlyFragmentTests | vk::PipelineStageFlagBits::eLateFragmentTests,
        .srcAccessMask = vk::AccessFlagBits::eShaderRead,
        .dstAccessMask = vk::AccessFlagBits::eColorAttachmentWrite | vk::AccessFlagBits::eDepthStencilAttachmentWrite
    };

    if (state.features.support_shader_interlock) {
        // Interlock writes must precede both attachment access and subsequent interlock draws.
        dependencies[1].srcAccessMask |= vk::AccessFlagBits::eShaderWrite;
        if (no_color) {
            dependencies[0].dstStageMask |= vk::PipelineStageFlagBits::eFragmentShader;
            dependencies[0].dstAccessMask |= vk::AccessFlagBits::eShaderRead | vk::AccessFlagBits::eShaderWrite;
            dependencies[1].dstStageMask |= vk::PipelineStageFlagBits::eFragmentShader;
            dependencies[1].dstAccessMask |= vk::AccessFlagBits::eShaderRead | vk::AccessFlagBits::eShaderWrite;
        } else if (state.features.use_mask_bit) {
            dependencies[0].dstStageMask |= vk::PipelineStageFlagBits::eFragmentShader;
            dependencies[0].dstAccessMask |= vk::AccessFlagBits::eInputAttachmentRead;
            dependencies[1].dstStageMask |= vk::PipelineStageFlagBits::eFragmentShader;
            dependencies[1].dstAccessMask |= vk::AccessFlagBits::eInputAttachmentRead;
        }
    }

    // The final layout transition covers the entire attachment, not just this macroblock.
    dependencies[2] = {
        .srcSubpass = 0,
        .dstSubpass = VK_SUBPASS_EXTERNAL,
        .srcStageMask = vk::PipelineStageFlagBits::eEarlyFragmentTests | vk::PipelineStageFlagBits::eLateFragmentTests,
        .dstStageMask = vk::PipelineStageFlagBits::eEarlyFragmentTests | vk::PipelineStageFlagBits::eLateFragmentTests,
        .srcAccessMask = vk::AccessFlagBits::eDepthStencilAttachmentWrite,
        .dstAccessMask = vk::AccessFlagBits::eDepthStencilAttachmentRead | vk::AccessFlagBits::eDepthStencilAttachmentWrite
    };

    // self-dependency
    // this allows us to use a pipeline barrier in the render pass for programmable blending
    dependencies[3] = {
        .srcSubpass = 0,
        .dstSubpass = 0,
        .srcStageMask = vk::PipelineStageFlagBits::eColorAttachmentOutput,
        .dstStageMask = vk::PipelineStageFlagBits::eFragmentShader,
        .srcAccessMask = vk::AccessFlagBits::eColorAttachmentWrite,
        .dstAccessMask = vk::AccessFlagBits::eInputAttachmentRead,
        .dependencyFlags = vk::DependencyFlagBits::eByRegion
    };

    // mid-scene flush
    // unity games use it to write to a buffer in a vertex shader then use it as the vertex input in the next draw
    dependencies[4] = {
        .srcSubpass = 0,
        .dstSubpass = 0,
        .srcStageMask = vk::PipelineStageFlagBits::eVertexShader,
        .dstStageMask = vk::PipelineStageFlagBits::eVertexInput,
        .srcAccessMask = vk::AccessFlagBits::eShaderWrite,
        .dstAccessMask = vk::AccessFlagBits::eVertexAttributeRead
    };

    vk::RenderPassCreateInfo pass_info{};
    vk::AttachmentDescription attachments[] = { color_attachment, ds_attachment };
    pass_info.setAttachments(attachments);
    pass_info.setSubpasses(subpass);
    pass_info.setDependencies(dependencies);
    if (no_color) {
        // only add the ds attachment
        pass_info.pAttachments = &attachments[1];
        pass_info.attachmentCount = 1;
        // no need for the self-dependency
        pass_info.setDependencyCount(3);
    }

    render_passes_map[format] = state.device.createRenderPass(pass_info);

    return render_passes_map[format];
}

#ifdef __APPLE__
// Bytes an attribute really reads: matrices are read as whole vec4s, and regformat attributes
// follow the shader's own type
static uint32_t metal_attribute_read_size(const SceGxmVertexAttribute &attribute, const VertexProgram *vkvert) {
    const auto widen = [](uint32_t components) {
        if (components > 4)
            return (components + 3) & ~3u;
        return components;
    };
    uint32_t size = gxm::attribute_format_size(static_cast<SceGxmAttributeFormat>(attribute.format)) * widen(attribute.componentCount);
    if (vkvert && vkvert->attribute_infos.contains(attribute.regIndex)) {
        const shader::usse::AttributeInformation &info = vkvert->attribute_infos.at(attribute.regIndex);
        if (info.regformat) {
            uint32_t components = info.component_count;
            uint32_t element = 4;
            switch (info.gxm_type) {
            case SCE_GXM_PARAMETER_TYPE_C10:
                components = (components * 10 + 7) / 8;
                element = 1;
                break;
            case SCE_GXM_PARAMETER_TYPE_U8:
            case SCE_GXM_PARAMETER_TYPE_S8:
                element = 1;
                break;
            case SCE_GXM_PARAMETER_TYPE_U16:
            case SCE_GXM_PARAMETER_TYPE_S16:
            case SCE_GXM_PARAMETER_TYPE_F16:
                element = 2;
                break;
            default:
                break;
            }
            size = std::max(size, element * widen(components));
        }
    }
    return std::max(size, 1u);
}

bool metal_realign_aligned_streams() {
    // Asked for every vertex stream of every draw: getenv each time (it takes the environment lock)
    // was a real cost at thousands of draws a frame. The value is set before a game starts, so
    // re-reading it twice a second is plenty.
    static std::atomic<bool> realign{ true };
    static std::atomic<int64_t> next_read_ms{ 0 };
    const int64_t now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    if (now_ms >= next_read_ms.load(std::memory_order_relaxed)) {
        const char *env = getenv("V3K_VERTEX_REALIGN");
        realign.store(!(env && env[0] == '0'), std::memory_order_relaxed);
        next_read_ms.store(now_ms + 500, std::memory_order_relaxed);
    }
    return realign.load(std::memory_order_relaxed);
}

MetalStreamLayout metal_stream_layout(const SceGxmVertexProgram &program, uint32_t stream_index) {
    MetalStreamLayout layout;
    const SceGxmVertexStream &stream = program.streams[stream_index];
    layout.src_stride = stream.stride;
    layout.stride = align(stream.stride, 4);
    const VertexProgram *vkvert = program.renderer_data.get();

    // Metal reads vertex attributes only at offsets that are multiples of 4 (Vulkan and the Vita allow
    // any offset): an attribute at offset 6 or 18 (normals, UVs and bone weights after a 3-component
    // position) was read from the wrong bytes, and character models came out bent or broken. Streams
    // with such an attribute are copied with every attribute in an aligned slot. Streams whose
    // attributes are all aligned keep reading the game's memory directly (copying every stream made
    // Persona 4 Golden's 3D scenes disappear). Odd strides are always copied (Metal strides must be
    // multiples of 4), with aligned slots when an attribute needs one.
    if (stream.stride % 4 == 0 && !metal_realign_aligned_streams())
        return layout;
    bool misaligned = false;
    for (uint32_t i = 0; i < program.attributes.size(); i++) {
        const SceGxmVertexAttribute &attribute = program.attributes[i];
        if (attribute.streamIndex == stream_index && attribute.offset % 4 != 0)
            misaligned = true;
    }
    if (!misaligned)
        return layout; // plain restride: same layout, stride rounded up to 4

    layout.repack = true;
    uint32_t cursor = 0;
    for (uint32_t i = 0; i < program.attributes.size(); i++) {
        const SceGxmVertexAttribute &attribute = program.attributes[i];
        if (attribute.streamIndex != stream_index)
            continue;
        const uint32_t read = metal_attribute_read_size(attribute, vkvert);
        layout.slots.push_back({ i, attribute.offset, read, cursor });
        cursor += align(read, 4);
    }
    // A zero stride repeats one vertex (constant attributes): keep it that way
    layout.stride = stream.stride == 0 ? 0 : std::max(cursor, 4u);
    return layout;
}

uint32_t metal_attribute_offset(const MetalStreamLayout &layout, uint32_t attribute_index, uint32_t original_offset) {
    for (const MetalVertexSlot &slot : layout.slots)
        if (slot.attribute == attribute_index)
            return slot.dst_offset;
    return original_offset;
}

std::vector<uint8_t> metal_repack_stream(const MetalStreamLayout &layout, const uint8_t *data, uint32_t size) {
    const uint32_t vertices = layout.src_stride == 0 ? 1 : (size + layout.src_stride - 1) / layout.src_stride;
    const uint32_t out_stride = layout.stride == 0 ? (layout.slots.empty() ? 4 : layout.slots.back().dst_offset + align(layout.slots.back().size, 4)) : layout.stride;
    std::vector<uint8_t> out(static_cast<size_t>(vertices) * out_stride, 0);
    for (uint32_t v = 0; v < vertices; v++) {
        const uint64_t base = static_cast<uint64_t>(v) * layout.src_stride;
        for (const MetalVertexSlot &slot : layout.slots) {
            const uint64_t from = base + slot.src_offset;
            if (from >= size)
                continue;
            const uint32_t bytes = static_cast<uint32_t>(std::min<uint64_t>(slot.size, size - from));
            memcpy(out.data() + static_cast<size_t>(v) * out_stride + slot.dst_offset, data + from, bytes);
        }
    }
    return out;
}
#endif

vk::PipelineVertexInputStateCreateInfo PipelineCache::get_vertex_input_state(const SceGxmVertexProgram &vertex_program, MemState &mem) {
    // pointer to these objects are returned (so it needs to be static)
    // and each thread needs one (hence the thread_local)
    static thread_local std::vector<vk::VertexInputBindingDescription> binding_descr;
    static thread_local std::vector<vk::VertexInputAttributeDescription> attr_descr;
    binding_descr.clear();
    attr_descr.clear();

    // Vertex attributes.
    VertexProgram *vkvert = vertex_program.renderer_data.get();

    uint32_t used_streams = 0;

#ifdef __APPLE__
    std::array<std::optional<MetalStreamLayout>, SCE_GXM_MAX_VERTEX_STREAMS> metal_layouts;
#endif
    for (uint32_t attribute_index = 0; attribute_index < vertex_program.attributes.size(); attribute_index++) {
        const SceGxmVertexAttribute &attribute = vertex_program.attributes[attribute_index];
        if (!vkvert->attribute_infos.contains(attribute.regIndex))
            continue;

        used_streams |= (1 << attribute.streamIndex);
        uint32_t attribute_offset = attribute.offset;
#ifdef __APPLE__
        auto &metal_layout = metal_layouts[attribute.streamIndex];
        if (!metal_layout)
            metal_layout = metal_stream_layout(vertex_program, attribute.streamIndex);
        attribute_offset = metal_attribute_offset(*metal_layout, attribute_index, attribute.offset);
#endif

        SceGxmAttributeFormat attribute_format = attribute.format;
        shader::usse::AttributeInformation info = vkvert->attribute_infos.at(attribute.regIndex);

        uint8_t component_count = attribute.componentCount;
        // these 2 values are only used when a matrix is used as a vertex attribute
        // this is only supported for regformated attribute for now
        // TODO: add support for matrix input for non-regformated attributes
        uint32_t array_size = 1;
        uint32_t array_element_size = 0;
        vk::Format format;
        if (info.regformat) {
            // use the data from the shader itself
            component_count = info.component_count;
            switch (info.gxm_type) {
            case SCE_GXM_PARAMETER_TYPE_U8:
            case SCE_GXM_PARAMETER_TYPE_S8:
            case SCE_GXM_PARAMETER_TYPE_C10:
                attribute_format = SCE_GXM_ATTRIBUTE_FORMAT_U8;
                break;
            case SCE_GXM_PARAMETER_TYPE_U16:
            case SCE_GXM_PARAMETER_TYPE_S16:
            case SCE_GXM_PARAMETER_TYPE_F16:
                attribute_format = SCE_GXM_ATTRIBUTE_FORMAT_U16;
                break;
            default:
                // U32 format
                attribute_format = SCE_GXM_ATTRIBUTE_FORMAT_UNTYPED;
                break;
            }

            if (info.gxm_type == SCE_GXM_PARAMETER_TYPE_C10)
                // this is 10-bit and not 8-bit
                component_count = (component_count * 10 + 7) / 8;

            if (component_count > 4) {
                // a matrix is used as an attribute, pack everything into an array of vec4
                array_size = (component_count + 3) / 4;
                array_element_size = 4 * gxm::attribute_format_size(attribute_format);
                component_count = 4;
            }

            // regformat attributes are int32
            format = translate_attribute_format(attribute_format, component_count, true, false);
            if (component_count == 3 && unsupported_rgb_vertex_attribute_formats.contains(format)) {
                component_count = 4;
                format = translate_attribute_format(attribute_format, component_count, true, false);
            }
        } else {
            // some Android GPUs do not support scaled attributes, do the conversion in the GPU instead
            if (!support_scaled_vertex_attribute)
                info.is_integer = true;

            // some AMD GPUs do not support rgb vertex attributes, so just put it as rgba
            // the 4th component will contain garbage but this is not an issue because the input
            // in the shader will be vec3 (or ivec3) and the 4th component will be discarded
            format = translate_attribute_format(attribute_format, component_count, info.is_integer, info.is_signed);
            if (component_count == 3 && unsupported_rgb_vertex_attribute_formats.contains(format)) {
                component_count = 4;
                format = translate_attribute_format(attribute_format, component_count, info.is_integer, info.is_signed);
            }
        }

        for (uint32_t i = 0; i < array_size; i++) {
            attr_descr.push_back(vk::VertexInputAttributeDescription{
                .location = info.location + i,
                .binding = attribute.streamIndex,
                .format = format,
                .offset = attribute_offset + i * array_element_size });
        }
    }

    for (unsigned int stream_index = 0; stream_index < SCE_GXM_MAX_VERTEX_STREAMS; stream_index++) {
        if (!(used_streams & (1 << stream_index)))
            continue;

        const SceGxmVertexStream &stream = vertex_program.streams[stream_index];

        const bool is_instanced = gxm::is_stream_instancing(static_cast<SceGxmIndexSource>(stream.indexSource));

#ifdef __APPLE__
        const uint32_t stride = metal_stream_layout(vertex_program, stream_index).stride;
#else
        const uint32_t stride = stream.stride;
#endif
        binding_descr.push_back(vk::VertexInputBindingDescription{
            .binding = stream_index,
            .stride = stride,
            .inputRate = is_instanced ? vk::VertexInputRate::eInstance : vk::VertexInputRate::eVertex });
    }

    vk::PipelineVertexInputStateCreateInfo vertex_input{};
    vertex_input.setVertexBindingDescriptions(binding_descr);
    vertex_input.setVertexAttributeDescriptions(attr_descr);
    return vertex_input;
}

void PipelineCache::compiler_thread(MemState &mem) {
    moodycamel::ConsumerToken consumer_token(pipeline_compile_queue);

    // just a single loop, waiting for a pipeline compile request and compiling it
    CompileRequest *request;
#if defined(VITA3K_PLATFORM_IOS)
    int thermal_qos = -1;
#endif
    while (true) {
        pipeline_compile_queue.wait_dequeue(consumer_token, request);

        if (request == nullptr)
            // use this as an instruction to stop the thread
            break;

        if (abandon_compiles.load(std::memory_order_acquire)) {
            // The game is being closed: the backlog is not worth compiling (Killzone's took 5 s to
            // work through before Quit finished). The pipelines are marked as failed and freed with the rest.
            *request->pipeline = failed_pipeline();
            request->vertex_program_gxm->compile_threads_on.fetch_sub(1, std::memory_order_release);
            request->fragment_program_gxm->compile_threads_on.fetch_sub(1, std::memory_order_release);
            delete request;
            continue;
        }

#if defined(VITA3K_PLATFORM_IOS)
        thermal::follow_worker_qos(thermal_qos);
        // Off screen, iOS refuses GPU work, and Metal building pipelines for a backgrounded app crashed
        // inside Apple's GPU driver on its own queue (Uncharted, after leaving the app). Hold the
        // request until the app is back (or the game closes).
        while (!app_activity::gpu_allowed().load(std::memory_order_acquire) && !abandon_compiles.load(std::memory_order_acquire))
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
#endif

        vk::Pipeline pipeline = compile_pipeline(request->type, request->render_pass, *request->vertex_program_gxm, *request->fragment_program_gxm, *request->get_record(), request->hints, mem);
        *request->pipeline = pipeline;

        request->vertex_program_gxm->compile_threads_on.fetch_sub(1, std::memory_order_release);
        request->fragment_program_gxm->compile_threads_on.fetch_sub(1, std::memory_order_release);

        const auto time_s = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
        next_pipeline_cache_save = time_s + pipeline_cache_save_delay;

        state.shaders_count_compiled++;

        delete request;
    }
}

static vk::StencilOpState convert_op_state(const GxmStencilStateOp &state) {
    return vk::StencilOpState{
        .failOp = translate_stencil_op(state.stencil_fail),
        .passOp = translate_stencil_op(state.depth_pass),
        .depthFailOp = translate_stencil_op(state.depth_fail),
        .compareOp = translate_stencil_func(state.func)
    };
}

vk::Pipeline PipelineCache::compile_pipeline(SceGxmPrimitiveType type, vk::RenderPass render_pass, const SceGxmVertexProgram &vertex_program_gxm, const SceGxmFragmentProgram &fragment_program_gxm, const GxmRecordState &record, const shader::Hints &hints, MemState &mem) {
    const VertexProgram &vertex_program = *vertex_program_gxm.renderer_data;
    const SceGxmProgram *gxm_fragment_shader = fragment_program_gxm.program.get(mem);
    const VKFragmentProgram &fragment_program = *reinterpret_cast<VKFragmentProgram *>(
        fragment_program_gxm.renderer_data.get());

    // the vertex input state must be computed before shader are retrieved in case symbols are stripped
    const vk::PipelineVertexInputStateCreateInfo vertex_input = get_vertex_input_state(vertex_program_gxm, mem);

    const bool maskupdate = fragment_program_gxm.is_maskupdate;
    // the write pass of a split vertex program: vertex stage only, nothing rasterized
    const bool store_pass = hints.vertex_store_pass && shader::splits_vertex_stores(*vertex_program_gxm.program.get(mem), state.features);
    const bool is_fragment_disabled = store_pass || (!maskupdate && (record.front_side_fragment_program_mode == SCE_GXM_FRAGMENT_PROGRAM_DISABLED || gxm_fragment_shader->has_no_effect()));
    const vk::PipelineShaderStageCreateInfo vertex_shader = retrieve_shader(vertex_program_gxm.program.get(mem), vertex_program.hash, true, false, mem, hints);
    vk::PipelineShaderStageCreateInfo fragment_shader;
    if (is_fragment_disabled && state.features.use_mask_bit && !store_pass) {
        const std::lock_guard<std::mutex> lock(shaders_mutex);
        if (!mask_test_shader) {
            const auto code = shader::create_mask_test_shader();
            const vk::ShaderModuleCreateInfo shader_info{
                .codeSize = code.size() * sizeof(uint32_t),
                .pCode = code.data()
            };
            mask_test_shader = state.device.createShaderModule(shader_info);
        }
        fragment_shader = {
            .stage = vk::ShaderStageFlagBits::eFragment,
            .module = mask_test_shader,
            .pName = "main_fs"
        };
    } else if (!is_fragment_disabled) {
        fragment_shader = retrieve_shader(gxm_fragment_shader, fragment_program.hash, false, maskupdate, mem, hints, record.is_gamma_corrected);
    }
    const vk::PipelineShaderStageCreateInfo shader_stages[] = { vertex_shader, fragment_shader };
    // Depth-only draws still need the mask test before depth/stencil updates.
    const uint32_t shader_stage_count = is_fragment_disabled && (!state.features.use_mask_bit || store_pass) ? 1U : 2U;

    const vk::PipelineInputAssemblyStateCreateInfo input_assembly{
        .topology = translate_primitive(type)
    };

    const bool two_sided = (record.two_sided == SCE_GXM_TWO_SIDED_ENABLED);

    const bool use_shader_interlock = !maskupdate && !is_fragment_disabled && !hints.masked_framebuffer_fetch && state.features.support_shader_interlock && gxm_fragment_shader->is_frag_color_used();

    const vk::PipelineRasterizationStateCreateInfo rasterizer{
        .rasterizerDiscardEnable = store_pass ? VK_TRUE : VK_FALSE,
        .polygonMode = translate_polygon_mode(record.front_polygon_mode),
        .cullMode = translate_cull_mode(record.cull_mode),
        // front face is always counter clockwise
        .frontFace = vk::FrontFace::eCounterClockwise,
        .depthBiasEnable = !maskupdate,
        .lineWidth = 1.0f
    };
    const vk::PipelineMultisampleStateCreateInfo multisampling{
        .rasterizationSamples = vk::SampleCountFlagBits::e1
    };
    // depth and stencil tests are always enabled on the ps vita as there is almost no cost in doing so
    // on a tiled renderer
    const vk::PipelineDepthStencilStateCreateInfo ds_info{
        .depthTestEnable = !maskupdate,
        .depthWriteEnable = !maskupdate && (record.front_depth_write_mode == SCE_GXM_DEPTH_WRITE_ENABLED),
        .depthCompareOp = translate_depth_func(record.front_depth_func),
        .depthBoundsTestEnable = VK_FALSE,
        .stencilTestEnable = !maskupdate,
        // GXM gives its front two-sided state to clockwise triangles (from Vita3K-Plus: fixes shadows)
        .front = convert_op_state(two_sided ? record.back_stencil_state_op : record.front_stencil_state_op),
        .back = convert_op_state(record.front_stencil_state_op)
    };

    vk::PipelineColorBlendStateCreateInfo color_blending{};
    if (!maskupdate && !is_fragment_disabled && support_coherent_framebuffer_fetch && gxm_fragment_shader->is_frag_color_used())
        color_blending.flags = vk::PipelineColorBlendStateCreateFlagBits::eRasterizationOrderAttachmentAccessEXT;

    const bool frag_has_no_output = static_cast<bool>(gxm_fragment_shader->program_flags & SCE_GXM_PROGRAM_FLAG_OUTPUT_UNDEFINED);
    if (maskupdate) {
        static const vk::PipelineColorBlendAttachmentState blending{
            .blendEnable = VK_FALSE,
            .colorWriteMask = vk::ColorComponentFlagBits::eR | vk::ColorComponentFlagBits::eG | vk::ColorComponentFlagBits::eB | vk::ColorComponentFlagBits::eA
        };
        color_blending.setAttachments(blending);
    } else if (is_fragment_disabled || frag_has_no_output || use_shader_interlock) {
        // The write mask must be empty as the lack of a fragment shader results in undefined values
        static const vk::PipelineColorBlendAttachmentState blending = {
            .blendEnable = VK_FALSE,
            .colorWriteMask = vk::ColorComponentFlags()
        };
        color_blending.setAttachments(blending);
    } else {
        const vk::PipelineColorBlendAttachmentState &blending = fragment_program.blending;
        color_blending.setAttachments(blending);
    }

    vk::PipelineLayout pipeline_layout = pipeline_layouts[vertex_program.texture_count][fragment_program.texture_count];

    // all of these can be changed at any time using the vita graphics api (like opengl)
    // Because each one can take a lot of different values, it's better to set them as dynamic
    const std::array dynamic_states = {
        vk::DynamicState::eViewport,
        vk::DynamicState::eScissor,
        vk::DynamicState::eStencilCompareMask,
        vk::DynamicState::eStencilReference,
        vk::DynamicState::eStencilWriteMask,
        vk::DynamicState::eDepthBias,
        vk::DynamicState::eLineWidth,
    };
    vk::PipelineDynamicStateCreateInfo dynamic_info{};
    dynamic_info.setDynamicStates(dynamic_states);
    if (!state.physical_device_features.wideLines)
        dynamic_info.dynamicStateCount--;

    // we still need to specify the viewport and scissor count even though they are dynamic
    vk::PipelineViewportStateCreateInfo viewport{
        .viewportCount = 1,
        .scissorCount = 1
    };

    vk::GraphicsPipelineCreateInfo pipeline_info{
        .stageCount = shader_stage_count,
        .pStages = shader_stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = &ds_info,
        .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_info,
        .layout = pipeline_layout,
        .renderPass = render_pass,
        .subpass = 0
    };

    // vulkan-hpp throws when the driver refuses the pipeline. On the background compile threads that
    // exception closed Vita3K (One Piece Burning Blood loading a 3D model): skip the draw instead.
    try {
        const auto result = state.device.createGraphicsPipeline(active_cache(), pipeline_info);
        if (result.result != vk::Result::eSuccess) {
            LOG_ERROR("Failed to create a pipeline ({})", vk::to_string(result.result));
            return failed_pipeline();
        }
        return result.value;
    } catch (const vk::SystemError &e) {
        LOG_ERROR("The GPU driver could not build a pipeline, its draws are skipped: {} (vertex shader {}, fragment shader {})", e.what(),
            hex_string(vertex_program_gxm.renderer_data->hash), hex_string(fragment_program_gxm.renderer_data->hash));
        return failed_pipeline();
    }
}

vk::Pipeline PipelineCache::retrieve_pipeline(VKContext &context, SceGxmPrimitiveType &type, bool consider_for_async, MemState &mem, bool vertex_store_pass) {
    const GxmRecordState &record = context.record;
    // get the hash of the current context
    uint64_t key = XXH3_64bits(&record, record_pipeline_len);
    if (vertex_store_pass)
        key ^= 0x9E3779B97F4A7C15ULL;
    if (context.shader_hints.masked_framebuffer_fetch)
        key ^= 0x7e46a312b5c098dfULL;

    // add the hash of the blending
    SceGxmFragmentProgram &fragment_program_gxm = *record.fragment_program.get(mem);
    const VKFragmentProgram &fragment_program = *reinterpret_cast<VKFragmentProgram *>(
        fragment_program_gxm.renderer_data.get());
    key ^= fragment_program.blending_hash;

    // add the hash of the attribute and stream layout
    SceGxmVertexProgram &vertex_program_gxm = *record.vertex_program.get(mem);
    key ^= vertex_program_gxm.key_hash;

    // and also add the primitive type
    key ^= static_cast<uint64_t>(type);

    // can't use constexpr because of apple clang...
    const vk::Pipeline pipeline_compiling = std::bit_cast<vk::Pipeline, uint64_t>(~0ULL);
    // if the pipeline is in the pipeline cache, we can expect its creation time to be almost instantaneous
    bool already_in_cache = false;

    auto it = pipelines.find(key);
    if (it != pipelines.end()) {
        if (it->second != nullptr) {
            if (it->second == pipeline_compiling || it->second == failed_pipeline())
                // pipeline is still compiling, or could not be built
                return nullptr;
            else
                return it->second;
        }
        already_in_cache = true;
    } else {
        // the pipeline hash was not in the cache;
        it = pipelines.insert({ key, pipeline_compiling }).first;
    }

    // get the correct renderpass here
    const SceGxmProgram *gxm_fragment_shader = fragment_program_gxm.program.get(mem);
    const bool maskupdate = fragment_program_gxm.is_maskupdate;
    const bool is_fragment_disabled = record.front_side_fragment_program_mode == SCE_GXM_FRAGMENT_PROGRAM_DISABLED || gxm_fragment_shader->has_no_effect();
    const bool use_shader_interlock = !maskupdate && !is_fragment_disabled && !context.shader_hints.masked_framebuffer_fetch && state.features.support_shader_interlock && gxm_fragment_shader->is_frag_color_used();
    const vk::RenderPass render_pass = maskupdate ? retrieve_mask_render_pass() : (use_shader_interlock ? context.current_shader_interlock_pass : context.current_render_pass);
    // update the shader hints
    context.shader_hints.color_format = record.color_surface.colorFormat;
    context.shader_hints.attributes = &vertex_program_gxm.attributes;
    context.shader_hints.vertex_store_pass = vertex_store_pass;

    // note: the flag can_use_deferred_compilation is not considered here because it causes way too many false positives
#ifdef __APPLE__
    // A pipeline known from the saved cache is not instant on Metal: MoltenVK keeps shader source, not
    // binaries, so Metal compiles it again each session, tens to hundreds of milliseconds each, on the
    // render thread, the first time every scene and effect appears. Those go to the workers as well
    // (ReVita measured the same on Xbox), so the first frames of a new scene can miss an object for a
    // moment instead of freezing.
    const bool compile_pipeline_async = !maskupdate && !context.shader_hints.masked_framebuffer_fetch && consider_for_async && use_async_compilation;
#else
    const bool compile_pipeline_async = !maskupdate && !context.shader_hints.masked_framebuffer_fetch && !already_in_cache && consider_for_async && use_async_compilation;
#endif

    if (compile_pipeline_async) {
        // create the pipeline compile request
        CompileRequest *request = new CompileRequest;
        *request = {
            .pipeline = &it->second,
            .type = type,
            .render_pass = render_pass,
            .vertex_program_gxm = &vertex_program_gxm,
            .fragment_program_gxm = &fragment_program_gxm,
            .hints = context.shader_hints
        };
        memcpy(request->record_data, &record, record_pipeline_len);
        it->second = pipeline_compiling;

        // we must not delete these programs until the worker is done
        vertex_program_gxm.compile_threads_on.fetch_add(1, std::memory_order_relaxed);
        fragment_program_gxm.compile_threads_on.fetch_add(1, std::memory_order_relaxed);

        pipeline_compile_queue.enqueue(pipeline_compile_queue_token, request);

#ifdef __APPLE__
        // Give the worker a few milliseconds before drawing without the pipeline: a shader Metal has
        // compiled before (its own cache) or a small one is usually ready by then, and the object
        // then shows up this frame instead of popping in a moment later. Bounded per draw and per
        // frame, so a scene with many new shaders still never stalls more than a few milliseconds.
        {
            static uint64_t budget_frame = 0;
            static int64_t budget_us = 0;
            constexpr int64_t per_draw_us = 3000;
            constexpr int64_t per_frame_us = 8000;
            if (budget_frame != state.frame_timestamp) {
                budget_frame = state.frame_timestamp;
                budget_us = per_frame_us;
            }
            if (budget_us > 0) {
                const auto start = std::chrono::steady_clock::now();
                const auto limit = start + std::chrono::microseconds(std::min(per_draw_us, budget_us));
                static_assert(sizeof(vk::Pipeline) == sizeof(uint64_t));
                uint64_t *const slot = reinterpret_cast<uint64_t *>(&it->second);
                const auto load = [slot] { return std::bit_cast<vk::Pipeline>(__atomic_load_n(slot, __ATOMIC_ACQUIRE)); };
                while (load() == pipeline_compiling && std::chrono::steady_clock::now() < limit)
                    std::this_thread::sleep_for(std::chrono::microseconds(200));
                budget_us -= std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start).count();
                const vk::Pipeline ready = load();
                if (ready != pipeline_compiling && ready != failed_pipeline())
                    return ready;
            }
        }
#endif
        return nullptr;
    } else {
        // can't wait, compile it right now
        vk::Pipeline result = compile_pipeline(type, render_pass, vertex_program_gxm, fragment_program_gxm, record, context.shader_hints, mem);

        const auto time_s = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
        next_pipeline_cache_save = time_s + pipeline_cache_save_delay;

        if (!already_in_cache)
            state.shaders_count_compiled++;

        it->second = result;

        return result == failed_pipeline() ? nullptr : result;
    }
}

vk::ShaderModule PipelineCache::precompile_shader(const Sha256Hash &hash, bool search_first) {
    if (search_first) {
        // happens while loading the thread, no parallel access so no need for a mutex
        auto it = shaders.find(hash);
        if (it != shaders.end())
            return it->second;
    }

    if (!fs::exists(state.shaders_path) || fs::is_empty(state.shaders_path))
        return nullptr;

    if (!manifest_lists(state, shaders_mutex, hash))
        return nullptr;

    Sha256Hash shader_hash;
    memcpy(shader_hash.data(), hash.data(), sizeof(Sha256Hash));
    const std::string shader_file_name = fmt::format("vk{}-{}.spv", shader::CURRENT_VERSION, hex_string(shader_hash));
    const std::vector<uint32_t> source = renderer::pre_load_shader_spirv(state.shaders_path / shader_file_name);

    if (source.empty())
        return nullptr;

    vk::ShaderModuleCreateInfo shader_info{
        .codeSize = sizeof(uint32_t) * source.size(),
        .pCode = source.data()
    };

    vk::ShaderModule shader = state.device.createShaderModule(shader_info);
    {
        std::lock_guard<std::mutex> guard(shaders_mutex);
        shaders[hash] = shader;
    }

    return shader;
}
} // namespace renderer::vulkan
