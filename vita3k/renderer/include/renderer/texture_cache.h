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

#pragma once

#include <gxm/types.h>
#include <util/containers.h>
#include <util/fs.h>

#include <array>
#include <cstdint>
#include <memory>
#include <string_view>
#include <vector>

namespace ddspp {
struct Descriptor;
}

struct MemState;

enum SceGxmTextureBaseFormat : uint32_t;

namespace renderer {
struct YUVConversionCache {
    void *sws_context = nullptr;
    size_t width = 0;
    size_t height = 0;
    bool is_p3 = false;
};

enum class Backend : uint32_t;
#if defined(VITA3K_PLATFORM_IOS)
// Slots, not memory (the memory budget in TextureCache limits that): Persona 4 Golden filled 1024 within
// 15 minutes, and Killzone Mercenary filled 2048 within 30 seconds of a level (368 MiB of a 1275 MiB
// budget). Once all slots are taken every new texture throws out one the frame still needs, which is
// uploaded again: Killzone fell from 30 FPS to 1-2. A slot costs a few hundred bytes.
static constexpr size_t TextureCacheSize = 8192;
#else
static constexpr size_t TextureCacheSize = 1024;
#endif

typedef std::array<uint32_t, 4> TextureGxmDataRepr;
struct TextureCacheInfo {
    // frame in which a draw last used this texture (see TextureCache::current_frame)
    uint64_t last_use_frame = 0;
    uint64_t hash = 0;
    SceGxmTexture texture;
    int index = 0;
    uint32_t texture_size = 0;
    bool use_hash = false;
    // no need for it to be atomic
    bool dirty = false;
    // used for texture importation
    bool is_imported = false;
    bool is_srgb = false;
    uint16_t width = 0;
    uint16_t height = 0;
    uint16_t mip_count = 0;
    SceGxmTextureBaseFormat format;
};

struct SamplerCacheInfo {
    // compact representation of the sampler state
    uint32_t value = 0;
    int index = 0;
};

struct AvailableTexture {
    bool is_dds;
    std::shared_ptr<fs::path> folder_path;
};

class TextureCache {
protected:
    // current texture info the cache is looking at
    TextureCacheInfo *current_info = nullptr;

    // are we in the process of exporting a texture
    bool exporting_texture = false;
    // are we in the process of importing a texture
    bool importing_texture = false;

    // dds/png raw file
    std::vector<uint8_t> imported_texture_raw_data;
    // pointer to the decoded content
    uint8_t *imported_texture_decoded = nullptr;
    // Info about the texture currently loading
    AvailableTexture loading_texture;
    // contain the decrypted header when loading dds
    ddspp::Descriptor *dds_descriptor = nullptr;
    // file being written to when exporting dds
    std::ofstream output_file;
    // used when exporting dds
    bool export_dds_swap_rb = false;

    bool import_textures = false;
    // if set to false, save textures as dds
    bool save_as_png = true;
    bool export_textures = false;

public:
    Backend backend;
    bool use_protect = false;
    YUVConversionCache yuv_conversion_cache;
    // use a separate sampler cache
    bool use_sampler_cache = false;
    int anisotropic_filtering = 1;

    // used to quickly get the info from a hash of a gxm_texture
    unordered_map_fast<TextureGxmDataRepr, TextureCacheInfo *> texture_lookup;
    lru::Queue<TextureCacheInfo> texture_queue;
    // reused by every upload instead of allocating a new buffer each time (from Vita3K-Plus)
    std::vector<uint8_t> scratch_decompressed;
    std::vector<uint8_t> scratch_lineared;

    // when use_sampler_cache is set to true, used to quickly get a cached sampler
    unordered_map_fast<uint32_t, SamplerCacheInfo *> sampler_lookup;
    lru::Queue<SamplerCacheInfo> sampler_queue;
    size_t last_bound_sampler_index;

    // folder where the replacement textures should be located
    fs::path import_folder;
    // key = hash, content = is the texture a dds (true) or a png (false)
    unordered_map_fast<uint64_t, AvailableTexture> available_textures_hash;

    // folder where the exported textures will be saved
    fs::path export_folder;
    // hash of the textures that have already been exported
    unordered_set_fast<uint64_t> exported_textures_hash;

    // smartphone GPUs do not support DXT (BC1/2/3/4/5) textures, they must be decompressed on the GPU
    bool support_dxt = false;
    // format for replaced texture, supported mostly by smartphone GPUs
    bool support_astc = false;
    // some smartphone GPUs do not support linear filtering on depth surfaces
    bool support_depth_linear_filtering = true;
    // powerVR only
    bool support_pvrt = false;
    // Whether this texture is uploaded as PVRTC (support_pvrt): only PVRTC 1 (Metal has no PVRTC 2),
    // square power-of-two swizzled textures of at least 8 texels (what Metal accepts)
    bool native_pvrt(const SceGxmTexture &gxm_texture) const;
    // other color format
    bool support_x8d24 = false;
    bool support_e5rgb9 = false;
    bool support_a2rgb10 = false;

    bool init(const bool hashless_texture_cache, const fs::path &texture_folder, const std::string_view game_id, const size_t sampler_cache_size = 0);
    void set_replacement_state(bool import_textures, bool export_textures, bool export_as_png);

    virtual void select(size_t index, const SceGxmTexture &texture) = 0;
    virtual void configure_texture(const SceGxmTexture &texture) = 0;
    virtual void upload_texture_impl(SceGxmTextureBaseFormat base_format, uint32_t width, uint32_t height, uint32_t mip_index, const void *pixels, int face, uint32_t pixels_per_stride) = 0;
    virtual void upload_done() {}

    virtual void configure_sampler(size_t index, const SceGxmTexture &texture, bool no_linear) {}

    // Graphics memory a cached texture holds (0 when it holds none), and dropping it. Used to keep the
    // cache within a memory budget on phones: the cache is sized by count (2048 textures), and a game
    // with big textures filled 2.2 GB of graphics memory with it and was closed by iOS.
    virtual uint64_t texture_memory(size_t index) const { return 0; }
    virtual void release_texture(size_t index) {}
    // Bytes the cached textures may use; 0 means no limit
    uint64_t memory_budget = 0;
    // Frames drawn so far (counted by the renderer at each new frame): keep_within_budget leaves alone
    // what the last few frames used, so a game whose working set is bigger than the budget doesn't drop
    // and upload the same textures again every frame (hitches, and both copies in memory meanwhile)
    uint64_t current_frame = 0;
    uint64_t memory_used = 0;
    uint32_t textures_held = 0;
    uint32_t seen_pressure = 0;
    void keep_within_budget(const TextureCacheInfo *keep);

    void upload_texture(const SceGxmTexture &gxm_texture, MemState &mem);
    void cache_and_bind_texture(const SceGxmTexture &gxm_texture, MemState &mem);

    // is called by cache_and_bind_texture if use_sampler_cache is set to true
    int cache_and_bind_sampler(const SceGxmTexture &gxm_texture, bool is_depth = false);

    // look at the texture folder and update the available imported / exported hashes
    void refresh_available_textures();

    // functions used for texture exportation
    void export_select(const SceGxmTexture &texture);
    void export_texture_impl(SceGxmTextureBaseFormat base_format, uint32_t width, uint32_t height, uint32_t mip_index, const void *pixels, int face, uint32_t pixels_per_stride);
    void export_done();

    // return false if there was an issue with the replacement texture
    bool import_configure_texture();
    virtual void import_configure_impl(SceGxmTextureBaseFormat base_format, uint32_t width, uint32_t height, bool is_srgb, uint16_t nb_components, uint16_t mipcount, bool swap_rb) = 0;
    void import_upload_texture();
    void import_done();

    virtual ~TextureCache();
};
} // namespace renderer
