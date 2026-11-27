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

#include <renderer/vulkan/functions.h>

#include <gxm/functions.h>
#include <renderer/vulkan/gxm_to_vulkan.h>
#include <shader/spirv_recompiler.h>

#include <config/state.h>
#include <spdlog/fmt/bin_to_hex.h>

#include <util/log.h>

#include <algorithm>
#include <cmath>
#include <set>
#include <unordered_map>

namespace renderer::vulkan {

void set_uniform_buffer(VKContext &context, MemState &mem, const ShaderProgram *program, const bool vertex_shader, const int block_num, const int size, Ptr<uint8_t> data) {
    auto offset = program->uniform_buffer_data_offsets.at(block_num);
    if (offset == static_cast<std::uint32_t>(-1)) {
        return;
    }

    const uint32_t data_size_upload = std::min<uint32_t>(size, program->uniform_buffer_sizes.at(block_num) * 4);
    if (context.state.features.enable_memory_mapping) {
        if (context.state.mapping_method == MappingMethod::DoubleBuffer) {
            // we must always cover everything as some small part of the buffer may get changed only
            context.state.buffer_trapping.access_buffer(data.address(), data_size_upload, mem, false, true);
        }

        const uint64_t buffer_address = context.state.get_matching_device_address(data.address());
        if (vertex_shader) {
            context.curr_vert_ublock.set_buffer_address(block_num, buffer_address);
        } else {
            context.curr_frag_ublock.set_buffer_address(block_num, buffer_address);
        }
    } else {
        const uint32_t offset_start_upload = offset * 4;

        if (vertex_shader) {
            if (!context.vertex_uniform_storage_allocated) {
                // Allocate a region for it. Don't worry though, when the shader program is changed
                context.vertex_uniform_stream_ring_buffer.allocate(program->max_total_uniform_buffer_storage * 4);
                context.vertex_uniform_storage_allocated = true;
            }

            context.vertex_uniform_stream_ring_buffer.copy(context.prerender_cmd, data_size_upload, data.get(mem), offset_start_upload);
        } else {
            if (!context.fragment_uniform_storage_allocated) {
                // Allocate a region for it. Don't worry though, when the shader program is changed
                context.fragment_uniform_stream_ring_buffer.allocate(program->max_total_uniform_buffer_storage * 4);
                context.fragment_uniform_storage_allocated = true;
            }

            context.fragment_uniform_stream_ring_buffer.copy(context.prerender_cmd, data_size_upload, data.get(mem), offset_start_upload);
        }
    }
}

void mid_scene_flush(VKContext &context, const SceGxmNotification notification) {
    // two cases :
    // notification.addr is 0: this means that the mid scene flush must be used as a barrier in the renderpass
    // notification.addr is not 0: this means the app is waiting for this part to be finished to re-use the resources

    // Note: however, when testing, the barrier inside a pipeline does not work (or not entirely, depending on the GPU)
    // maybe because I'm writing using buffer device addresses, not sure...
    // so for the time being always restart the render pass
    // const bool restart_render_pass = notification.address.address() != 0;
    const bool restart_render_pass = true;

    if (restart_render_pass && context.in_renderpass)
        context.stop_render_pass();

    // in case there is no notification, this will happen in the render pass
    vk::MemoryBarrier barrier{
        .srcAccessMask = vk::AccessFlagBits::eShaderWrite,
        .dstAccessMask = vk::AccessFlagBits::eVertexAttributeRead,
    };
    context.render_cmd.pipelineBarrier(vk::PipelineStageFlagBits::eVertexShader, vk::PipelineStageFlagBits::eVertexInput,
        vk::DependencyFlags(), barrier, {}, {});

    if (restart_render_pass) {
        SceGxmNotification empty_notification = { Ptr<uint32_t>(0), 0 };
        const bool submit = notification.address.address() != 0;
        context.stop_recording(notification, empty_notification, submit);
        context.start_recording();
        context.scene_timestamp++;
    }
}

#ifdef __APPLE__
// restride vertex attribute binding strides to multiple of 4
// needed for metal because it only allows multiples of 4.
// The copy goes to a buffer kept for the renderer thread: no allocation per draw.
static std::vector<uint8_t> &restride_scratch() {
    static thread_local std::vector<uint8_t> scratch;
    return scratch;
}

void restride_stream(const uint8_t *&stream, uint32_t &size, uint32_t stride) {
    const uint32_t new_stride = align(stride, 4);
    const uint32_t nb_vertex_input = ((size + stride - 1) / stride);

    std::vector<uint8_t> &new_data = restride_scratch();
    if (new_data.size() < static_cast<size_t>(nb_vertex_input) * new_stride)
        new_data.resize(static_cast<size_t>(nb_vertex_input) * new_stride);
    for (uint32_t i = 0; i < nb_vertex_input; i++) {
        // the last vertex may be cut short by the stream size
        const uint32_t bytes = std::min(stride, size - stride * i);
        memcpy(new_data.data() + new_stride * i, stream + stride * i, bytes);
    }

    stream = new_data.data();
    size = nb_vertex_input * new_stride;
}

// Metal layouts per vertex program and stream, computed once instead of for every draw. The key
// covers the attribute and stream layout (key_hash) and the shader (its address), which decides the
// attribute sizes of regformat inputs.
static const MetalStreamLayout &cached_metal_layout(const SceGxmVertexProgram &program, int stream) {
    static thread_local std::unordered_map<uint64_t, MetalStreamLayout> cache;
    const uint64_t key = ((program.key_hash ^ (static_cast<uint64_t>(program.program.address()) * 0x9E3779B97F4A7C15ULL)) * 31 + static_cast<uint64_t>(stream)) * 2
        + (metal_realign_aligned_streams() ? 1 : 0);
    auto it = cache.find(key);
    if (it == cache.end()) {
        if (cache.size() > 4096)
            cache.clear();
        it = cache.emplace(key, metal_stream_layout(program, stream)).first;
    }
    return it->second;
}
#endif

// when needed, how many descriptor of the given size we allocate for each frame at once
static constexpr uint32_t DESCRIPTOR_PACK_SIZE = 64;

static vk::DescriptorSet retrieve_descriptor(VKContext &context, bool is_vertex, uint16_t textures_count) {
    if (textures_count == 0)
        return context.empty_set;

    VKState &state = context.state;
    FrameDescriptor &frame_descriptor = is_vertex ? state.frame().vert_descriptors[textures_count - 1] : state.frame().frag_descriptors[textures_count - 1];
    if (frame_descriptor.descriptors_idx < frame_descriptor.sets.size())
        return frame_descriptor.sets[frame_descriptor.descriptors_idx++];

    // we have no more frame descriptor available, create a bunch of new one for this specific layout
    vk::DescriptorPoolSize pool_size{
        .type = vk::DescriptorType::eCombinedImageSampler,
        .descriptorCount = textures_count * DESCRIPTOR_PACK_SIZE * MAX_FRAMES_RENDERING
    };

    vk::DescriptorPoolCreateInfo descriptor_pool_info{
        .maxSets = DESCRIPTOR_PACK_SIZE * MAX_FRAMES_RENDERING
    };
    descriptor_pool_info.setPoolSizes(pool_size);

    vk::DescriptorPool descriptor_pool = state.device.createDescriptorPool(descriptor_pool_info);
    state.frame_descriptor_pools.push_back(descriptor_pool);

    // allocate all the descriptor sets
    const vk::DescriptorSetLayout set_layout = is_vertex ? state.pipeline_cache.vertex_textures_layout[textures_count] : state.pipeline_cache.fragment_textures_layout[textures_count];
    std::vector<vk::DescriptorSetLayout> layouts(DESCRIPTOR_PACK_SIZE * MAX_FRAMES_RENDERING, set_layout);
    vk::DescriptorSetAllocateInfo descr_set_info{
        .descriptorPool = descriptor_pool
    };
    descr_set_info.setSetLayouts(layouts);
    auto descriptor_sets = state.device.allocateDescriptorSets(descr_set_info);

    // distribute them among all frames
    for (int frame_idx = 0; frame_idx < MAX_FRAMES_RENDERING; frame_idx++) {
        FrameObject &frame_object = state.frames[frame_idx];
        FrameDescriptor &frame_descr = is_vertex ? frame_object.vert_descriptors[textures_count - 1] : frame_object.frag_descriptors[textures_count - 1];

        // insert DESCRIPTOR_PACK_SIZE in each frame descriptor
        auto descr_it = descriptor_sets.begin() + frame_idx * DESCRIPTOR_PACK_SIZE;
        frame_descr.sets.insert(frame_descr.sets.end(), descr_it, descr_it + DESCRIPTOR_PACK_SIZE);
    }

    return frame_descriptor.sets[frame_descriptor.descriptors_idx++];
}

static void draw_bind_descriptors(VKContext &context, MemState &mem) {
    VKState &state = context.state;

    std::array<vk::DescriptorSet, 4> descriptors;
    descriptors[0] = context.global_set;
    descriptors[1] = context.rendertarget_set;

    const uint16_t vertex_textures_count = context.record.vertex_program.get(mem)->renderer_data->texture_count;
    const uint16_t fragment_texture_count = context.record.fragment_program.get(mem)->renderer_data->texture_count;

    vk::PipelineLayout pipeline_layout = state.pipeline_cache.pipeline_layouts[vertex_textures_count][fragment_texture_count];

    // try to use last descriptor if it still matches
    bool need_vert_descr = (vertex_textures_count != context.last_vert_texture_count);
    bool need_frag_descr = (fragment_texture_count != context.last_frag_texture_count);

    context.last_vert_texture_count = vertex_textures_count;
    context.last_frag_texture_count = fragment_texture_count;

    {
        if (need_vert_descr) {
            context.last_vert_texture_descriptor = retrieve_descriptor(context, true, vertex_textures_count);
        }
        descriptors[2] = context.last_vert_texture_descriptor;

        if (need_frag_descr) {
            context.last_frag_texture_descriptor = retrieve_descriptor(context, false, fragment_texture_count);
        }
        descriptors[3] = context.last_frag_texture_descriptor;
    }

    // bind textures
    std::array<vk::WriteDescriptorSet, 16> write_descrs;
    // some default sampler in case a slot has never been set and we read a slot with higher idx
    vk::DescriptorImageInfo default_image_info{
        .sampler = context.state.default_image.sampler,
        .imageView = context.state.default_image.view,
        .imageLayout = vk::ImageLayout::eGeneral
    };

    // vertex
    if (need_vert_descr) {
        for (uint32_t i = 0; i < vertex_textures_count; i++) {
            write_descrs[i] = vk::WriteDescriptorSet{
                .dstSet = descriptors[2],
                .dstBinding = i,
                .dstArrayElement = 0,
                .descriptorType = vk::DescriptorType::eCombinedImageSampler,
            };
            write_descrs[i].setImageInfo(context.vertex_textures[i].sampler ? context.vertex_textures[i] : default_image_info);
        }
        state.device.updateDescriptorSets(vertex_textures_count, write_descrs.data(), 0, nullptr);
    }

    // fragment
    if (need_frag_descr) {
        for (uint32_t i = 0; i < fragment_texture_count; i++) {
            write_descrs[i] = vk::WriteDescriptorSet{
                .dstSet = descriptors[3],
                .dstBinding = i,
                .dstArrayElement = 0,
                .descriptorType = vk::DescriptorType::eCombinedImageSampler,
            };
            write_descrs[i].setImageInfo(context.fragment_textures[i].sampler ? context.fragment_textures[i] : default_image_info);
        }
        state.device.updateDescriptorSets(fragment_texture_count, write_descrs.data(), 0, nullptr);
    }

    const uint32_t dynamic_offset_count = state.features.enable_memory_mapping ? 2U : 4U;
    const uint32_t dynamic_offsets[] = {
        // GXMRenderVertUniformBlock
        context.vertex_info_uniform_buffer.data_offset,
        // GXMRenderFragUniformBlock
        context.fragment_info_uniform_buffer.data_offset,
        // vertex ssbo
        context.vertex_uniform_stream_ring_buffer.data_offset,
        // fragment ssbo
        context.fragment_uniform_stream_ring_buffer.data_offset
    };

    context.render_cmd.bindDescriptorSets(vk::PipelineBindPoint::eGraphics, pipeline_layout, 0,
        descriptors.size(), descriptors.data(), dynamic_offset_count, dynamic_offsets);
}

#ifdef __APPLE__
// Diagnostics only: logs vertex layouts that Metal may read differently from a PS Vita (attribute
// offsets that are not 4-byte aligned, attributes running past the stride, odd strides), once per
// vertex program, so rendering problems on iOS can be matched to the layouts a game uses
static void log_metal_vertex_layout(const SceGxmVertexProgram &program, int stream_count) {
    static std::set<const void *> logged;
    if (logged.size() >= 40 || logged.contains(&program))
        return;
    logged.insert(&program);
    std::string details;
    for (int i = 0; i < stream_count; i++) {
        const SceGxmVertexStream &stream = program.streams[i];
        bool unusual = stream.stride % 4 != 0;
        std::string attributes;
        for (const SceGxmVertexAttribute &attribute : program.attributes) {
            if (attribute.streamIndex != i)
                continue;
            const uint32_t size = gxm::attribute_format_size(static_cast<SceGxmAttributeFormat>(attribute.format)) * attribute.componentCount;
            if (attribute.offset % std::min<uint32_t>(4, size) != 0 || (stream.stride != 0 && attribute.offset + size > stream.stride))
                unusual = true;
            attributes += fmt::format(" [off {} fmt {} x{}]", static_cast<uint32_t>(attribute.offset), static_cast<int>(attribute.format), static_cast<int>(attribute.componentCount));
        }
        if (unusual)
            details += fmt::format(" stream {} stride {}:{}", i, static_cast<uint32_t>(stream.stride), attributes);
    }
    if (!details.empty())
        LOG_INFO("Metal vertex layout check:{}", details);
}
#endif

// vertex count is only used with double buffer mapping (and on Apple for the streams that must be copied)
static void bind_vertex_streams(VKContext &context, MemState &mem, uint32_t instance_count, uint32_t max_index,
    const void *index_data, size_t index_count, SceGxmIndexFormat index_format) {
    GxmRecordState &state = context.record;
    const SceGxmVertexProgram &vertex_program = *state.vertex_program.get(mem);
    VertexProgram *vkvert = vertex_program.renderer_data.get();

    int max_stream_idx = -1;

    for (const SceGxmVertexAttribute &attribute : vertex_program.attributes) {
        if (!vkvert->attribute_infos.contains(attribute.regIndex))
            continue;
        max_stream_idx = std::max<int>(max_stream_idx, attribute.streamIndex);
    }
    max_stream_idx++;

    if (context.state.mapping_method == MappingMethod::DoubleBuffer) {
        for (int i = 0; i < max_stream_idx; i++)
            state.vertex_streams[i].size = 0;

        // same as in SceGxm.cpp
        for (const SceGxmVertexAttribute &attribute : vertex_program.attributes) {
            const SceGxmAttributeFormat attribute_format = static_cast<SceGxmAttributeFormat>(attribute.format);
            const size_t attribute_size = gxm::attribute_format_size(attribute_format) * attribute.componentCount;
            const SceGxmVertexStream &stream = vertex_program.streams[attribute.streamIndex];
            const SceGxmIndexSource index_source = static_cast<SceGxmIndexSource>(stream.indexSource);
            const size_t data_passed_length = gxm::is_stream_instancing(index_source) ? ((instance_count - 1) * stream.stride) : (max_index * stream.stride);
            const size_t data_length = attribute.offset + data_passed_length + attribute_size;
            state.vertex_streams[attribute.streamIndex].size = std::max<size_t>(state.vertex_streams[attribute.streamIndex].size, data_length);
        }

        for (int i = 0; i < max_stream_idx; i++) {
            if (state.vertex_streams[i].data)
                // on the PS Vita, shader stores are used most of the time to write to a vertex buffer
                context.state.buffer_trapping.access_buffer(state.vertex_streams[i].data.address(), static_cast<uint32_t>(state.vertex_streams[i].size), mem, context.state.has_shader_store);
        }
    }

    if (max_stream_idx == 0)
        return;

#ifdef __APPLE__
    // With memory mapping on, the GXM side doesn't look at the indices, so each stream's length covers only
    // the first vertex: fine when the GPU reads the game's memory directly, but a stream Metal makes us copy
    // (odd stride, unaligned attributes or address) then had only its first vertex copied and every other
    // vertex read zeros. With page-table mapping that drew huge triangles all pointing at one spot (Madden
    // NFL 13's stadium and field). Measure those streams from the indices here, as double buffer does.
    if (context.state.features.enable_memory_mapping && context.state.mapping_method != MappingMethod::DoubleBuffer) {
        bool copied = false;
        for (int i = 0; i < max_stream_idx; i++) {
            if (!state.vertex_streams[i].data)
                continue;
            const MetalStreamLayout &layout = cached_metal_layout(vertex_program, i);
            if (vertex_program.streams[i].stride % 4 != 0 || layout.repack || (state.vertex_streams[i].data.address() & 3) != 0)
                copied = true;
        }
        if (copied) {
            if (max_index == 0 && index_data && index_count) {
                if (index_format == SCE_GXM_INDEX_FORMAT_U16) {
                    const uint16_t *data = static_cast<const uint16_t *>(index_data);
                    max_index = *std::max_element(data, data + index_count);
                } else {
                    const uint32_t *data = static_cast<const uint32_t *>(index_data);
                    max_index = *std::max_element(data, data + index_count);
                }
            }
            for (const SceGxmVertexAttribute &attribute : vertex_program.attributes) {
                const size_t attribute_size = gxm::attribute_format_size(static_cast<SceGxmAttributeFormat>(attribute.format)) * attribute.componentCount;
                const SceGxmVertexStream &stream = vertex_program.streams[attribute.streamIndex];
                const SceGxmIndexSource index_source = static_cast<SceGxmIndexSource>(stream.indexSource);
                const size_t passed = gxm::is_stream_instancing(index_source) ? ((instance_count > 0 ? instance_count - 1 : 0) * stream.stride) : (static_cast<size_t>(max_index) * stream.stride);
                const size_t length = attribute.offset + passed + attribute_size;
                state.vertex_streams[attribute.streamIndex].size = std::max<size_t>(state.vertex_streams[attribute.streamIndex].size, length);
            }
        }
    }
    log_metal_vertex_layout(vertex_program, max_stream_idx);
#endif
    for (int i = 0; i < max_stream_idx; i++) {
        if (state.vertex_streams[i].data) {
            bool read_from_mapping = context.state.features.enable_memory_mapping;
#ifdef __APPLE__
            // Vulkan allows any stride and offset, but Metal only allows multiples of 4: copy those streams
            // Odd strides are copied with the stride rounded up to 4; when attributes sit at unaligned
            // offsets, the copy gives each attribute an aligned slot (metal_stream_layout)
            const MetalStreamLayout &metal_layout = cached_metal_layout(vertex_program, i);
            const bool restride = vertex_program.streams[i].stride % 4 != 0 && !metal_layout.repack;
            if (restride || metal_layout.repack || (state.vertex_streams[i].data.address() & 3) != 0)
                read_from_mapping = false;
            if (metal_layout.repack)
                LOG_INFO_ONCE("Realigning vertex attributes for Metal (stride {} -> {})", metal_layout.src_stride, metal_layout.stride);
#endif
            if (read_from_mapping) {
                auto [buffer, offset] = context.state.get_matching_mapping(state.vertex_streams[i].data.cast<void>());

                context.vertex_stream_offsets[i] = offset;
                context.vertex_stream_buffers[i] = buffer;
            } else {
                const uint8_t *stream = state.vertex_streams[i].data.get(mem);
                uint32_t stream_size = state.vertex_streams[i].size;
#ifdef __APPLE__
                std::vector<uint8_t> repacked;
                if (metal_layout.repack) {
                    repacked = metal_repack_stream(metal_layout, stream, stream_size);
                    stream = repacked.data();
                    stream_size = static_cast<uint32_t>(repacked.size());
                } else if (restride) {
                    restride_stream(stream, stream_size, vertex_program.streams[i].stride);
                }
#endif
                context.vertex_stream_ring_buffer.allocate(context.prerender_cmd, stream_size, stream);
                // The copy lives in the ring buffer: bind that buffer, not whatever this slot held before. With
                // memory mapping on (where the slots start as, and usually are, mapping buffers), a copied
                // stream kept the previous draw's buffer with the ring buffer's offset and its vertices were
                // read from unrelated memory: the giant triangles shooting out of Madden NFL 13's field
                context.vertex_stream_buffers[i] = context.vertex_stream_ring_buffer.handle();
                context.vertex_stream_offsets[i] = context.vertex_stream_ring_buffer.data_offset;
            }

            state.vertex_streams[i].data = nullptr;
            state.vertex_streams[i].size = 0;
        }
    }

    context.render_cmd.bindVertexBuffers(0, max_stream_idx, context.vertex_stream_buffers, context.vertex_stream_offsets);
}

struct OrderedMaskIndices {
    vk::Buffer buffer;
    uint32_t offset;
    uint32_t count;
};

static OrderedMaskIndices prepare_ordered_mask_indices(VKContext &context, SceGxmPrimitiveType type,
    SceGxmIndexFormat format, Ptr<void> indices, size_t count, MemState &mem) {
    const size_t primitive_count = count > 2 ? count - 2 : 0;
    const uint32_t index_size = format == SCE_GXM_INDEX_FORMAT_U16 ? 2 : 4;
    if (primitive_count > std::numeric_limits<uint32_t>::max() / (3 * index_size)) {
        LOG_ERROR("Masked framebuffer fetch index expansion is too large: {} indices", count);
        throw std::runtime_error("Masked framebuffer fetch index expansion exceeds buffer limits");
    }
    const uint32_t output_count = static_cast<uint32_t>(primitive_count * 3);
    if (!output_count)
        return { nullptr, 0, 0 };

    std::vector<vk::BufferCopy> copies;
    copies.reserve(output_count);
    for (size_t primitive = 0; primitive < primitive_count; ++primitive) {
        // Keep the first (provoking) vertex while correcting alternating strip winding.
        const std::array<size_t, 3> vertices = type == SCE_GXM_PRIMITIVE_TRIANGLE_FAN
            ? std::array<size_t, 3>{ 0, primitive + 1, primitive + 2 }
            : std::array<size_t, 3>{ primitive, primitive + 1 + (primitive & 1), primitive + 2 - (primitive & 1) };
        for (const auto vertex : vertices)
            copies.push_back({ vertex * index_size, copies.size() * index_size, index_size });
    }

    if (!context.state.features.enable_memory_mapping) {
        const auto *source = indices.cast<uint8_t>().get(mem);
        vkutil::Buffer expanded(output_count * index_size);
        expanded.init_buffer(vk::BufferUsageFlagBits::eIndexBuffer, vkutil::vma_mapped_alloc);
        auto *destination = static_cast<uint8_t *>(expanded.mapped_data);
        for (const auto &copy : copies)
            memcpy(destination + copy.dstOffset, source + copy.srcOffset, index_size);
        context.state.allocator.flushAllocation(expanded.allocation, 0, VK_WHOLE_SIZE);
        const auto buffer = expanded.buffer;
        context.state.frame().destroy_queue.add_buffer(expanded);
        return { buffer, 0, output_count };
    }

    if (context.state.mapping_method == MappingMethod::DoubleBuffer)
        context.state.buffer_trapping.access_buffer(indices.address(), count * index_size, mem);
    const auto [source, source_offset] = context.state.get_matching_mapping(indices);
    for (auto &copy : copies)
        copy.srcOffset += source_offset;

    if (context.in_renderpass)
        context.stop_render_pass();
    const vk::MemoryBarrier source_barrier{
        .srcAccessMask = vk::AccessFlagBits::eMemoryWrite,
        .dstAccessMask = vk::AccessFlagBits::eTransferRead
    };
    context.render_cmd.pipelineBarrier(vk::PipelineStageFlagBits::eAllCommands, vk::PipelineStageFlagBits::eTransfer,
        {}, source_barrier, {}, {});
    vkutil::Buffer expanded(output_count * index_size);
    expanded.init_buffer(vk::BufferUsageFlagBits::eTransferDst | vk::BufferUsageFlagBits::eIndexBuffer);
    context.render_cmd.copyBuffer(source, expanded.buffer, copies);
    const vk::MemoryBarrier index_barrier{
        .srcAccessMask = vk::AccessFlagBits::eTransferWrite,
        .dstAccessMask = vk::AccessFlagBits::eIndexRead
    };
    context.render_cmd.pipelineBarrier(vk::PipelineStageFlagBits::eTransfer, vk::PipelineStageFlagBits::eVertexInput,
        {}, index_barrier, {}, {});
    const auto buffer = expanded.buffer;
    context.state.frame().destroy_queue.add_buffer(expanded);
    return { buffer, 0, output_count };
}

static void framebuffer_fetch_barrier(VKContext &context) {
    const vk::MemoryBarrier barrier{
        .srcAccessMask = vk::AccessFlagBits::eColorAttachmentWrite,
        .dstAccessMask = vk::AccessFlagBits::eInputAttachmentRead
    };
    context.render_cmd.pipelineBarrier(vk::PipelineStageFlagBits::eColorAttachmentOutput, vk::PipelineStageFlagBits::eFragmentShader,
        vk::DependencyFlagBits::eByRegion, barrier, {}, {});
}

void draw(VKContext &context, SceGxmPrimitiveType type, SceGxmIndexFormat format,
    Ptr<void> indices, size_t count, uint32_t instance_count, MemState &mem, const Config &config) {
    const SceGxmFragmentProgram &gxm_fragment_program = *context.record.fragment_program.get(mem);

    void *indices_ptr = indices.get(mem);

    context.check_for_macroblock_change(true);

    const bool maskupdate = gxm_fragment_program.is_maskupdate;
    const SceGxmProgram &fragment_program_gxp = *gxm_fragment_program.program.get(mem);
    const bool uses_framebuffer_fetch = !maskupdate && fragment_program_gxp.is_frag_color_used()
        && context.record.front_side_fragment_program_mode != SCE_GXM_FRAGMENT_PROGRAM_DISABLED && !fragment_program_gxp.has_no_effect();
    const bool masked_fetch = uses_framebuffer_fetch && context.state.features.should_use_shader_interlock()
        && context.state.features.use_mask_bit && context.render_target->mask_may_reject;
    const bool ordered_fetch = masked_fetch && !context.state.support_rasterized_order_access;
    if (context.shader_hints.masked_framebuffer_fetch != masked_fetch) {
        context.shader_hints.masked_framebuffer_fetch = masked_fetch;
        context.refresh_pipeline = true;
    }
    std::optional<OrderedMaskIndices> ordered_indices;
    if (ordered_fetch && (type == SCE_GXM_PRIMITIVE_TRIANGLE_STRIP || type == SCE_GXM_PRIMITIVE_TRIANGLE_FAN)) {
        ordered_indices = prepare_ordered_mask_indices(context, type, format, indices, count, mem);
        type = SCE_GXM_PRIMITIVE_TRIANGLES;
    }
#ifdef __APPLE__
    // Metal has no triangle fans and MoltenVK does not emulate them (portability subset: triangleFans
    // is false): a fan drawn anyway comes out as long stray slivers. Expand fans into triangle lists
    // on the CPU: (v0, vk, vk+1) for each k.
    static thread_local std::vector<uint8_t> fan_indices;
    fan_indices.clear();
    uint32_t fan_max_index = 0;
    if (type == SCE_GXM_PRIMITIVE_TRIANGLE_FAN && !ordered_indices) {
        if (count < 3)
            return;
        const size_t fan_index_size = (format == SCE_GXM_INDEX_FORMAT_U16) ? 2 : 4;
        const size_t triangles = count - 2;
        fan_indices.resize(triangles * 3 * fan_index_size);
        const auto expand = [&]<typename T>(const T *source) {
            T *out = reinterpret_cast<T *>(fan_indices.data());
            for (size_t i = 0; i < count; i++)
                fan_max_index = std::max<uint32_t>(fan_max_index, source[i]);
            for (size_t k = 0; k < triangles; k++) {
                out[k * 3] = source[0];
                out[k * 3 + 1] = source[k + 1];
                out[k * 3 + 2] = source[k + 2];
            }
        };
        if (fan_index_size == 2)
            expand(static_cast<const uint16_t *>(indices_ptr));
        else
            expand(static_cast<const uint32_t *>(indices_ptr));
        count = triangles * 3;
        type = SCE_GXM_PRIMITIVE_TRIANGLES;
        LOG_INFO_ONCE("Triangle fans are drawn as triangle lists (Metal has no triangle fans)");
    }
#endif
    if (masked_fetch)
        LOG_INFO_ONCE("Using late-tested framebuffer fetch for rejecting GXM masks; programmable blending is ordered per primitive when rasterization-order attachment access is unavailable");

    if (context.in_renderpass && context.in_maskupdate_pass != maskupdate)
        context.stop_render_pass();

    if (!context.in_renderpass)
        context.start_render_pass(true, maskupdate);

    // a draw whose color nothing observes and which leaves depth and stencil untouched has no effect,
    // unless it counts samples for a visibility query (the render pass is started above so the scene still clears)
    if (context.record.skip_color_output && !may_write_depth_stencil(context.record)
        && !(context.current_visibility_buffer != nullptr && context.current_query_idx != -1)) {
        for (auto &stream : context.record.vertex_streams) {
            stream.data = nullptr;
            stream.size = 0;
        }
        context.vertex_uniform_storage_allocated = false;
        context.fragment_uniform_storage_allocated = false;
        return;
    }

    // when we do multiple render pass for one scene (shader interlock or slow macroblock),
    // we need to always load the depth-stencil after the first draw
    if (!maskupdate && context.is_first_scene_draw && (context.state.features.support_shader_interlock || context.state.features.use_mask_bit || context.ignore_macroblock)) {
        // update the render pass to load and store the depth and stencil
        context.current_render_pass = context.state.pipeline_cache.retrieve_render_pass(context.current_color_format, true, true, !context.record.color_surface.data);
        context.is_first_scene_draw = false;
    }

    const bool uses_interlock = uses_framebuffer_fetch && context.state.features.support_shader_interlock && !masked_fetch;
    if (!maskupdate && context.state.features.support_shader_interlock
        && uses_interlock != context.last_draw_was_framebuffer_fetch) {
        // restart the render pass to act as a barrier
        context.end_visibility_query();
        context.render_cmd.endRenderPass();

        if (uses_interlock) {
            context.curr_renderpass_info.framebuffer = context.current_shader_interlock_framebuffer;
            context.curr_renderpass_info.renderPass = context.current_shader_interlock_pass;
        } else {
            context.curr_renderpass_info.framebuffer = context.current_framebuffer;
            context.curr_renderpass_info.renderPass = context.current_render_pass;
        }

        context.render_cmd.beginRenderPass(context.curr_renderpass_info, vk::SubpassContents::eInline);
        context.last_draw_was_framebuffer_fetch = uses_interlock;
    }
    // nothing can observe the color when the previous draws did not write any (upstream 141dce00)
    if (uses_framebuffer_fetch && (masked_fetch || (context.state.features.direct_fragcolor && !context.record.skip_color_output)))
        framebuffer_fetch_barrier(context);

    if (!maskupdate && context.current_visibility_buffer != nullptr && context.current_query_idx != -1 && !context.is_in_query) {
        context.begin_visibility_query();
    }

    // do we need to check for a pipeline change?
    if (context.refresh_pipeline || type != context.last_primitive) {
        context.refresh_pipeline = false;
        context.last_primitive = type;

        // We don't want to defer cases where we draw a whole quad over the screen as these draws could be necessary
        // to be able to see anything
        bool can_be_whole_quad = instance_count == 1 && count <= 6;
        vk::Pipeline new_pipeline = context.state.pipeline_cache.retrieve_pipeline(context, type, !can_be_whole_quad, mem);
        // a vertex program that writes memory: its writes run in a second, unrasterized pass
        context.vertex_store_pipeline = !maskupdate && shader::splits_vertex_stores(*context.record.vertex_program.get(mem)->program.get(mem), context.state.features)
            ? context.state.pipeline_cache.retrieve_pipeline(context, type, false, mem, true)
            : vk::Pipeline{};

        if (new_pipeline != context.current_pipeline) {
            context.current_pipeline = new_pipeline;

            if (new_pipeline != nullptr)
                context.render_cmd.bindPipeline(vk::PipelineBindPoint::eGraphics, context.current_pipeline);
        }
    }

    // can happen with asynchronous pipeline compilation
    if (context.current_pipeline == nullptr)
        return;

    if (config.log_active_shaders) {
        const std::string hash_text_f = hex_string(context.record.fragment_program.get(mem)->renderer_data->hash);
        const std::string hash_text_v = hex_string(context.record.vertex_program.get(mem)->renderer_data->hash);

        LOG_DEBUG("\nVertex  : {}\nFragment: {}", hash_text_v, hash_text_f);
        LOG_DEBUG("Vertex default uniform buffer: {}\n", spdlog::to_hex(context.ubo_data[0], 16));
        LOG_DEBUG("Fragment default uniform buffer: {}\n", spdlog::to_hex(context.ubo_data[SCE_GXM_REAL_MAX_UNIFORM_BUFFER], 16));
    }

    const bool use_memory_mapping = context.state.features.enable_memory_mapping;

    // update uniforms if needed
    // first update the buffer and texture count
    auto &vert_render_data = context.record.vertex_program.get(mem)->renderer_data;
    auto &frag_render_data = context.record.fragment_program.get(mem)->renderer_data;

    if (use_memory_mapping) {
        context.curr_vert_ublock.set_buffer_count(vert_render_data->buffer_count);
        context.curr_frag_ublock.set_buffer_count(frag_render_data->buffer_count);
    }

    if (context.state.features.use_texture_viewport) {
        context.curr_vert_ublock.set_texture_count(vert_render_data->texture_count);
        context.curr_frag_ublock.set_texture_count(frag_render_data->texture_count);
    }

    auto &vert_ublock = context.curr_vert_ublock.base_block;
    vert_ublock.viewport_flip = context.record.viewport_flip;
    vert_ublock.viewport_flag = (context.record.viewport_flat) ? 0.0f : 1.0f;
    vert_ublock.z_offset = context.record.z_offset;
    vert_ublock.z_scale = context.record.z_scale;
    vert_ublock.screen_width = context.render_target->width / context.state.res_multiplier;
    vert_ublock.screen_height = context.render_target->height / context.state.res_multiplier;
    // widescreen hack: only for draws into frame-shaped targets (the game's screen), not shadow maps or other buffers
    vert_ublock.wide_x_scale = 1.0f;
    if (context.state.widescreen_x_scale != 1.0f && vert_ublock.screen_height > 0.0f) {
        // Screen-shaped: the Vita's 960x544 or a scaled-down copy (720x408, 640x368, 480x272: games that
        // render 3D below native resolution), judged by the viewport the draw uses when it has one, so
        // games that draw their scene into a bigger or power-of-two target (1024x512, 1024x1024) get it too
        // Any landscape shape from 3:2 to 2:1 counts: games draw their 3D scene at 960x544, 16:9 (1024x576,
        // 854x480), 5:3 (800x480) or 3:2 (720x480), and the narrow window around 960x544 left those out
        // (widescreen "only working in some games"). Shadow maps and other square or tall buffers stay out.
        const auto screen_shaped = [&](float w, float h) {
            if (h <= 0.0f || w < 256.0f)
                return false;
            const float aspect = w / h;
            return aspect >= 1.45f && aspect <= 2.1f;
        };
        const bool target_shaped = screen_shaped(vert_ublock.screen_width, vert_ublock.screen_height);
        const bool viewport_shaped = !context.record.viewport_flat && screen_shaped(std::abs(context.viewport.width), std::abs(context.viewport.height));
        if (target_shaped || viewport_shaped)
            vert_ublock.wide_x_scale = context.state.widescreen_x_scale;
    }
    vert_ublock.wide_attr_shift = 0.0f;
    if (vert_ublock.wide_x_scale != 1.0f) {
        // 2D draws the game places at a projected 3D point: move their centre with the widened view, keep their size.
        // Their positions are in pixels from the screen centre, so the centre moves from cx to cx * scale.
        static constexpr std::array<uint8_t, 4> anchored_shaders[] = {
            { 0x15, 0x42, 0x9e, 0xde }, // FIFA 15: player marker and other on-pitch icons
        };
        const auto &vhash = vert_render_data->hash;
        bool anchored = false;
        for (const auto &prefix : anchored_shaders)
            anchored |= std::equal(prefix.begin(), prefix.end(), vhash.begin());
        const SceGxmVertexProgram &vp = *context.record.vertex_program.get(mem);
        for (const SceGxmVertexAttribute &a : vp.attributes) {
            if (!anchored || a.regIndex != 0 || a.format != SCE_GXM_ATTRIBUTE_FORMAT_F32 || a.streamIndex >= vp.streams.size())
                continue;
            const auto &stream = context.record.vertex_streams[a.streamIndex];
            if (!stream.data)
                break;
            const uint8_t *bytes = stream.data.get(mem);
            const uint32_t stride = vp.streams[a.streamIndex].stride;
            const void *index_data = indices.get(mem);
            float x0 = 1e30f, x1 = -1e30f;
            for (size_t v = 0; v < std::min<size_t>(count, 64); v++) {
                uint32_t vi = static_cast<uint32_t>(v);
                if (index_data && format == SCE_GXM_INDEX_FORMAT_U16)
                    vi = static_cast<const uint16_t *>(index_data)[v];
                else if (index_data)
                    vi = static_cast<const uint32_t *>(index_data)[v];
                float x;
                memcpy(&x, bytes + static_cast<size_t>(vi) * stride + a.offset, sizeof(x));
                x0 = std::min(x0, x);
                x1 = std::max(x1, x);
            }
            if (x0 <= x1)
                vert_ublock.wide_attr_shift = (x0 + x1) * 0.5f * (vert_ublock.wide_x_scale - 1.0f);
            break;
        }
    }

    if (context.curr_vert_ublock.changed || memcmp(&context.prev_vert_ublock, &vert_ublock, sizeof(vert_ublock)) != 0) {
        // TODO: this intermediate step can be avoided
        context.curr_vert_ublock.copy_to(context.shader_info_temp);
        context.vertex_info_uniform_buffer.allocate(context.prerender_cmd, context.curr_vert_ublock.get_size(), context.shader_info_temp);
        memcpy(&context.prev_vert_ublock, &vert_ublock, sizeof(vert_ublock));
    }

    auto &frag_ublock = context.curr_frag_ublock.base_block;
    frag_ublock.writing_mask = context.record.writing_mask;
    frag_ublock.res_multiplier = context.state.res_multiplier;
    const bool has_msaa = context.render_target->multisample_mode;
    const bool has_downscale = context.record.color_surface.downscale;
    if (has_msaa && !has_downscale)
        frag_ublock.res_multiplier *= 2;
    else if (!has_msaa && has_downscale)
        frag_ublock.res_multiplier /= 2;

    if (context.curr_frag_ublock.changed || memcmp(&context.prev_frag_ublock, &frag_ublock, sizeof(frag_ublock)) != 0) {
        // TODO: this intermediate step can be avoided
        context.curr_frag_ublock.copy_to(context.shader_info_temp);
        context.fragment_info_uniform_buffer.allocate(context.prerender_cmd, context.curr_frag_ublock.get_size(), context.shader_info_temp);
        memcpy(&context.prev_frag_ublock, &frag_ublock, sizeof(frag_ublock));
    }

    // create, update and bind descriptors (uniforms and textures)
    draw_bind_descriptors(context, mem);

    // Upload index data.
    vk::IndexType index_type = (format == SCE_GXM_INDEX_FORMAT_U16) ? vk::IndexType::eUint16 : vk::IndexType::eUint32;
    const size_t index_size = (format == SCE_GXM_INDEX_FORMAT_U16) ? 2 : 4;

    uint32_t max_index = 0;
#ifdef __APPLE__
    if (!fan_indices.empty()) {
        context.index_stream_ring_buffer.allocate(context.prerender_cmd, static_cast<uint32_t>(fan_indices.size()), fan_indices.data());
        context.render_cmd.bindIndexBuffer(context.index_stream_ring_buffer.handle(), context.index_stream_ring_buffer.data_offset, index_type);
        max_index = fan_max_index;
    } else
#endif
        if (use_memory_mapping) {
        auto [buffer, offset] = context.state.get_matching_mapping(indices);
        if (context.state.mapping_method == MappingMethod::DoubleBuffer) {
            TrappedBuffer *trapped_buffer = context.state.buffer_trapping.access_buffer(indices.address(), count * index_size, mem);
            if (trapped_buffer->extra == ~0) {
                // store the max element in extra
                if (format == SCE_GXM_INDEX_FORMAT_U16) {
                    uint16_t *data = indices.cast<uint16_t>().get(mem);
                    trapped_buffer->extra = *std::max_element(&data[0], &data[count]);
                } else {
                    uint32_t *data = indices.cast<uint32_t>().get(mem);
                    trapped_buffer->extra = *std::max_element(&data[0], &data[count]);
                }
            }
            max_index = trapped_buffer->extra;
        }
#ifdef __APPLE__
        if ((offset & 3) != 0) {
            // Metal needs a 4-byte aligned index buffer offset: copy the indices instead
            context.index_stream_ring_buffer.allocate(context.prerender_cmd, index_size * count, indices_ptr);
            context.render_cmd.bindIndexBuffer(context.index_stream_ring_buffer.handle(), context.index_stream_ring_buffer.data_offset, index_type);
        } else
#endif
            context.render_cmd.bindIndexBuffer(buffer, offset, index_type);
    } else if (!ordered_indices) {
        const size_t index_buffer_size = index_size * count;
        context.index_stream_ring_buffer.allocate(context.prerender_cmd, index_buffer_size, indices_ptr);
        context.render_cmd.bindIndexBuffer(context.index_stream_ring_buffer.handle(), context.index_stream_ring_buffer.data_offset, index_type);
    }

    // bind the vertex streams
    bind_vertex_streams(context, mem, instance_count, max_index, indices_ptr, count, format);

    if (ordered_fetch) {
        if (ordered_indices) {
            count = ordered_indices->count;
            if (count)
                context.render_cmd.bindIndexBuffer(ordered_indices->buffer, ordered_indices->offset, index_type);
        }
        const uint32_t vertices_per_primitive = type == SCE_GXM_PRIMITIVE_POINTS ? 1U : type == SCE_GXM_PRIMITIVE_LINES ? 2U
                                                                                                                        : 3U;
        for (uint32_t instance = 0; instance < instance_count; ++instance) {
            for (size_t first = 0; first + vertices_per_primitive <= count; first += vertices_per_primitive) {
                framebuffer_fetch_barrier(context);
                context.render_cmd.drawIndexed(vertices_per_primitive, 1, static_cast<uint32_t>(first), 0, instance);
            }
        }
    } else {
        context.render_cmd.drawIndexed(count, instance_count, 0, 0, 0);
    }
    if (context.vertex_store_pipeline && count && instance_count) {
        // the same vertices again, this time with the vertex program's memory writes and nothing drawn
        context.render_cmd.bindPipeline(vk::PipelineBindPoint::eGraphics, context.vertex_store_pipeline);
        context.render_cmd.drawIndexed(count, instance_count, 0, 0, 0);
        context.render_cmd.bindPipeline(vk::PipelineBindPoint::eGraphics, context.current_pipeline);
        context.vertex_store_draws++;
    }
    if (maskupdate && count && instance_count && context.record.writing_mask < 0.5f)
        context.render_target->mask_may_reject = true;

    context.vertex_uniform_storage_allocated = false;
    context.fragment_uniform_storage_allocated = false;
}

} // namespace renderer::vulkan
