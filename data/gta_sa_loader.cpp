#include "dynos.cpp.h"

// dynos.cpp.h defines min/max/clamp as macros; keep them away from STL headers.
#ifdef min
#undef min
#endif
#ifdef max
#undef max
#endif
#ifdef clamp
#undef clamp
#endif

extern "C" {
#include "pc/lua/smlua.h"
#include <PR/gbi.h>
#include "geo_commands.h"
}

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <limits>
#include <string>
#include <vector>

#include "rw.h"

namespace {

constexpr uint64_t GTA_IMG_SECTOR_SIZE = 2048;
constexpr uint32_t GTA_MAX_IMG_ENTRIES = 200000;
constexpr uint32_t GTA_MAX_FILE_BYTES = 256 * 1024 * 1024;
constexpr size_t GTA_MAX_TRIANGLES = 200000;
constexpr size_t GTA_TRIANGLES_PER_PART = 900;

struct ImgEntry {
    std::string name;
    uint64_t offset = 0;
    uint64_t size = 0;
};

struct GtaSkinBinding {
    rw::Skin* skin = nullptr;
    rw::HAnimHierarchy* hierarchy = nullptr;
    std::vector<rw::Frame*> boneFrames;
    std::vector<rw::Matrix> skinMatrices;
    std::vector<uint8_t> validSkinMatrices;
};

struct GtaVertex {
    rw::V3d sourcePosition = { 0.0f, 0.0f, 0.0f };
    rw::Frame* staticFrame = nullptr;
    uint32_t skinBinding = UINT32_MAX;
    uint8_t boneIndices[4] = { 0, 0, 0, 0 };
    float boneWeights[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    uint8_t r = 255;
    uint8_t g = 255;
    uint8_t b = 255;
    uint8_t a = 255;
    Vtx* target = nullptr;
};

struct GtaTriangle {
    GtaVertex v[3];
};

struct IfpKeyFrame {
    rw::Quat rotation = { 0.0f, 0.0f, 0.0f, 1.0f };
    rw::V3d translation = { 0.0f, 0.0f, 0.0f };
    rw::V3d scale = { 1.0f, 1.0f, 1.0f };
    float time = 0.0f;
    bool hasTranslation = false;
    bool hasScale = false;
};

struct IfpTrack {
    std::string name;
    int32_t sourceBoneId = -1;
    int32_t boneId = -1;
    uint32_t frameType = 0;
    uint32_t sourceIndex = 0;
    int32_t targetNode = -1;
    std::vector<IfpKeyFrame> keyFrames;
};

struct IfpAnimationInfo {
    std::string name;
    uint32_t tracks = 0;
    uint32_t frames = 0;
    float duration = 0.0f;
    uint32_t matchedById = 0;
    uint32_t mappedByOrder = 0;
    std::vector<IfpTrack> trackData;
};

struct IfpInfo {
    std::string version;
    std::string internalName;
    std::vector<IfpAnimationInfo> animations;
};

struct GtaModelState {
    uint32_t modelId = 0;
    float scale = 100.0f;
    rw::Clump* clump = nullptr;
    rw::HAnimHierarchy* hierarchy = nullptr;
    std::vector<rw::Frame*> boneFrames;
    std::vector<rw::Matrix> restMatrices;
    std::vector<GtaSkinBinding> skinBindings;
    std::vector<GtaTriangle> triangles;
    std::vector<IfpAnimationInfo> animations;
    int32_t activeAnimation = -1;
    float animationTime = 0.0f;
};

rw::TexDictionary* sCurrentGtaTxd = nullptr;
bool sRwReady = false;
uint32_t sGtaModelSerial = 0;
std::vector<GtaModelState*> sGtaModels;

uint32_t read_u32_le(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

uint16_t read_u16_le(const uint8_t* p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

int16_t read_i16_le(const uint8_t* p) {
    const uint16_t raw = read_u16_le(p);
    int16_t value = 0;
    std::memcpy(&value, &raw, sizeof(value));
    return value;
}

float read_f32_le(const uint8_t* p) {
    const uint32_t raw = read_u32_le(p);
    float value = 0.0f;
    std::memcpy(&value, &raw, sizeof(value));
    return value;
}

bool read_file(const std::string& path, std::vector<uint8_t>& out, std::string& error) {
    std::ifstream file(path.c_str(), std::ios::binary | std::ios::ate);
    if (!file) {
        error = "No se pudo abrir: " + path;
        return false;
    }

    const std::streamoff size = file.tellg();
    if (size < 0 || (uint64_t)size > GTA_MAX_FILE_BYTES) {
        error = "El archivo supera el límite de lectura de 256 MiB.";
        return false;
    }

    out.resize((size_t)size);
    file.seekg(0, std::ios::beg);
    if (!out.empty() && !file.read(reinterpret_cast<char*>(out.data()), size)) {
        error = "No se pudo leer el archivo completo: " + path;
        out.clear();
        return false;
    }
    return true;
}

bool parse_img_v2(const std::string& path, std::vector<ImgEntry>& entries, std::string& error) {
    std::ifstream file(path.c_str(), std::ios::binary | std::ios::ate);
    if (!file) {
        error = "No se pudo abrir el IMG: " + path;
        return false;
    }

    const std::streamoff fileSize = file.tellg();
    if (fileSize < 8) {
        error = "El archivo IMG es demasiado pequeño.";
        return false;
    }

    file.seekg(0, std::ios::beg);
    uint8_t header[8] = {};
    file.read(reinterpret_cast<char*>(header), sizeof(header));
    if (!file || std::memcmp(header, "VER2", 4) != 0) {
        error = "Formato IMG no compatible: se requiere IMG v2 con cabecera VER2.";
        return false;
    }

    const uint32_t count = read_u32_le(header + 4);
    if (count > GTA_MAX_IMG_ENTRIES ||
        8ULL + (uint64_t)count * 32ULL > (uint64_t)fileSize) {
        error = "La tabla de entradas IMG está corrupta o fuera de los límites.";
        return false;
    }

    entries.clear();
    entries.reserve(count);
    uint8_t record[32];
    for (uint32_t i = 0; i < count; ++i) {
        file.read(reinterpret_cast<char*>(record), sizeof(record));
        if (!file) {
            error = "La tabla IMG terminó antes de lo esperado.";
            entries.clear();
            return false;
        }

        const uint32_t offsetSectors = read_u32_le(record);
        const uint16_t streamSectors = read_u16_le(record + 4);
        const uint16_t sizeSectors = read_u16_le(record + 6);
        const uint32_t sectors = sizeSectors ? sizeSectors : streamSectors;
        if (sectors == 0) {
            continue;
        }

        ImgEntry entry;
        size_t nameLength = 0;
        while (nameLength < 24 && record[8 + nameLength] != 0) {
            ++nameLength;
        }
        entry.name.assign(reinterpret_cast<const char*>(record + 8), nameLength);
        entry.offset = (uint64_t)offsetSectors * GTA_IMG_SECTOR_SIZE;
        entry.size = (uint64_t)sectors * GTA_IMG_SECTOR_SIZE;

        if (entry.offset > (uint64_t)fileSize ||
            entry.size > (uint64_t)fileSize - entry.offset) {
            error = "Una entrada IMG apunta fuera del archivo: " + entry.name;
            entries.clear();
            return false;
        }
        entries.push_back(entry);
    }
    return true;
}

bool read_img_entry(const std::string& path, const std::string& entryName,
                    std::vector<uint8_t>& data, std::string& error) {
    std::vector<ImgEntry> entries;
    if (!parse_img_v2(path, entries, error)) {
        return false;
    }

    const auto sameName = [](const std::string& a, const std::string& b) {
        if (a.size() != b.size()) return false;
        for (size_t i = 0; i < a.size(); ++i) {
            if (std::tolower((unsigned char)a[i]) !=
                std::tolower((unsigned char)b[i])) return false;
        }
        return true;
    };

    const ImgEntry* found = nullptr;
    for (const ImgEntry& entry : entries) {
        if (sameName(entry.name, entryName)) {
            found = &entry;
            break;
        }
    }
    if (!found) {
        error = "No existe '" + entryName + "' dentro de " + path;
        return false;
    }
    if (found->size == 0 || found->size > GTA_MAX_FILE_BYTES) {
        error = "El recurso IMG supera el límite de lectura.";
        return false;
    }

    std::ifstream file(path.c_str(), std::ios::binary);
    if (!file) {
        error = "No se pudo volver a abrir el IMG.";
        return false;
    }
    file.seekg((std::streamoff)found->offset, std::ios::beg);
    data.resize((size_t)found->size);
    if (!file.read(reinterpret_cast<char*>(data.data()), (std::streamsize)data.size())) {
        error = "No se pudo leer la entrada IMG: " + entryName;
        data.clear();
        return false;
    }
    return true;
}

bool ensure_renderware() {
    if (sRwReady) return true;
    if (rw::Engine::state == rw::Engine::Dead) {
        if (!rw::Engine::init()) return false;
        rw::registerHAnimPlugin();
        rw::registerNativeDataPlugin();
        rw::registerSkinPlugin();
        rw::registerMatFXPlugin();
        rw::registerMeshPlugin();
        rw::registerAtomicRightsPlugin();
        rw::registerMaterialRightsPlugin();
        rw::registerUVAnimPlugin();
        rw::registerUserDataPlugin();
        rw::registerAnisotropyPlugin();
        if (!rw::Engine::open(nullptr)) return false;
        if (!rw::Engine::start()) return false;
    }
    sRwReady = rw::Engine::state == rw::Engine::Started;
    return sRwReady;
}

bool load_txd_from_img(const std::string& path, const std::string& entryName,
                       std::string& error) {
    std::vector<uint8_t> bytes;
    if (!read_img_entry(path, entryName, bytes, error)) return false;
    if (!ensure_renderware()) {
        error = "No se pudo iniciar el lector RenderWare.";
        return false;
    }

    rw::StreamMemory stream;
    stream.open(bytes.data(), (uint32_t)bytes.size());
    uint32_t length = 0, version = 0;
    if (!rw::findChunk(&stream, rw::ID_TEXDICTIONARY, &length, &version)) {
        error = "La entrada no contiene un Texture Dictionary TXD válido.";
        return false;
    }

    rw::TexDictionary* dictionary = rw::TexDictionary::streamRead(&stream);
    if (!dictionary) {
        error = "RenderWare no pudo interpretar el TXD (formato nativo no compatible o datos dañados).";
        return false;
    }

    if (sCurrentGtaTxd) {
        sCurrentGtaTxd->destroy();
        sCurrentGtaTxd = nullptr;
    }
    sCurrentGtaTxd = dictionary;
    rw::TexDictionary::setCurrent(dictionary);
    return true;
}

rw::RGBA get_material_color(rw::Material* material) {
    rw::RGBA color = { 255, 255, 255, 255 };
    if (material) color = material->color;
    return color;
}

uint8_t multiply_color(uint8_t a, uint8_t b) {
    return (uint8_t)(((uint16_t)a * (uint16_t)b + 127) / 255);
}

GtaVertex make_vertex(const rw::V3d& position, rw::Frame* frame,
                      float scale, const rw::RGBA& materialColor,
                      const rw::RGBA* vertexColor,
                      const rw::Geometry* geometry, rw::Skin* skin,
                      uint32_t skinBinding, uint32_t sourceVertex) {
    (void)scale;
    GtaVertex out;
    out.sourcePosition = position;
    out.staticFrame = frame;
    out.skinBinding = UINT32_MAX;
    out.r = materialColor.red;
    out.g = materialColor.green;
    out.b = materialColor.blue;
    out.a = materialColor.alpha;

    if (vertexColor) {
        out.r = multiply_color(out.r, vertexColor->red);
        out.g = multiply_color(out.g, vertexColor->green);
        out.b = multiply_color(out.b, vertexColor->blue);
        out.a = multiply_color(out.a, vertexColor->alpha);
    }

    if (geometry && skin && skinBinding != UINT32_MAX &&
        sourceVertex < (uint32_t)geometry->numVertices &&
        skin->indices && skin->weights && skin->numBones > 0) {
        bool hasInfluence = false;
        for (uint32_t influence = 0; influence < 4; ++influence) {
            const size_t offset = (size_t)sourceVertex * 4 + influence;
            const uint8_t bone = skin->indices[offset];
            const float weight = skin->weights[offset];
            if (bone >= skin->numBones || !std::isfinite(weight) || weight <= 0.00001f) {
                continue;
            }
            out.boneIndices[influence] = bone;
            out.boneWeights[influence] = weight;
            hasInfluence = true;
        }
        if (hasInfluence) out.skinBinding = skinBinding;
    }
    return out;
}

void append_triangle(std::vector<GtaTriangle>& triangles,
                     const rw::V3d& a, const rw::V3d& b, const rw::V3d& c,
                     rw::Frame* frame, float scale,
                     const rw::RGBA& materialColor,
                     const rw::RGBA* colorA, const rw::RGBA* colorB,
                     const rw::RGBA* colorC,
                     const rw::Geometry* geometry, rw::Skin* skin,
                     uint32_t skinBinding,
                     uint32_t indexA, uint32_t indexB, uint32_t indexC) {
    if (triangles.size() >= GTA_MAX_TRIANGLES) return;
    GtaTriangle triangle;
    triangle.v[0] = make_vertex(a, frame, scale, materialColor, colorA,
                                geometry, skin, skinBinding, indexA);
    triangle.v[1] = make_vertex(b, frame, scale, materialColor, colorB,
                                geometry, skin, skinBinding, indexB);
    triangle.v[2] = make_vertex(c, frame, scale, materialColor, colorC,
                                geometry, skin, skinBinding, indexC);
    triangles.push_back(triangle);
}

bool read_native_vertex(const uint8_t* source, uint32_t stride, uint32_t localIndex,
                        uint32_t sourceVertexIndex, uint32_t colorOffset,
                        rw::Frame* frame, float scale,
                        const rw::RGBA& materialColor,
                        const rw::Geometry* geometry, rw::Skin* skin,
                        uint32_t skinBinding, GtaVertex& out) {
    if (!source || stride < 12) return false;
    const uint8_t* vertex = source + (size_t)localIndex * stride;
    rw::V3d position;
    std::memcpy(&position.x, vertex + 0, sizeof(float));
    std::memcpy(&position.y, vertex + 4, sizeof(float));
    std::memcpy(&position.z, vertex + 8, sizeof(float));

    out = make_vertex(position, frame, scale, materialColor, nullptr,
                      geometry, skin, skinBinding, sourceVertexIndex);
    if (colorOffset != UINT32_MAX && colorOffset + 4 <= stride) {
        uint32_t argb = 0;
        std::memcpy(&argb, vertex + colorOffset, sizeof(argb));
        const uint8_t r = (uint8_t)((argb >> 16) & 0xFF);
        const uint8_t g = (uint8_t)((argb >> 8) & 0xFF);
        const uint8_t b = (uint8_t)(argb & 0xFF);
        const uint8_t a = (uint8_t)((argb >> 24) & 0xFF);
        out.r = multiply_color(out.r, r);
        out.g = multiply_color(out.g, g);
        out.b = multiply_color(out.b, b);
        out.a = multiply_color(out.a, a);
    }
    return true;
}

uint32_t create_skin_binding(std::vector<GtaSkinBinding>& bindings,
                             rw::Atomic* atomic,
                             rw::Geometry* geometry,
                             rw::HAnimHierarchy* fallbackHierarchy) {
    rw::Skin* skin = rw::Skin::get(geometry);
    if (!skin || !skin->indices || !skin->weights || !skin->inverseMatrices ||
        skin->numBones <= 0) return UINT32_MAX;

    rw::HAnimHierarchy* hierarchy = rw::Skin::getHierarchy(atomic);
    if (!hierarchy && atomic->getFrame()) {
        hierarchy = rw::HAnimHierarchy::find(atomic->getFrame());
    }
    if (!hierarchy) hierarchy = fallbackHierarchy;
    if (!hierarchy || hierarchy->numNodes <= 0) return UINT32_MAX;

    hierarchy->attach();
    GtaSkinBinding binding;
    binding.skin = skin;
    binding.hierarchy = hierarchy;
    binding.boneFrames.resize((size_t)skin->numBones, nullptr);

    for (int32_t bone = 0; bone < skin->numBones; ++bone) {
        rw::Frame* frame = nullptr;
        for (int32_t node = 0; node < hierarchy->numNodes; ++node) {
            const rw::HAnimNodeInfo& info = hierarchy->nodeInfo[node];
            if (info.index == bone && info.frame) {
                frame = info.frame;
                break;
            }
        }
        if (!frame && bone < hierarchy->numNodes) {
            frame = hierarchy->nodeInfo[bone].frame;
        }
        binding.boneFrames[(size_t)bone] = frame;
    }

    const uint32_t index = (uint32_t)bindings.size();
    bindings.push_back(binding);
    return index;
}

void append_native_mesh(std::vector<GtaTriangle>& triangles,
                        const rw::d3d8::InstanceData& instance,
                        const rw::Geometry* geometry,
                        rw::Frame* frame,
                        rw::Skin* skin, uint32_t skinBinding,
                        float scale) {
    if (!instance.vertexBuffer || !instance.indexBuffer ||
        instance.numVertices <= 0 || instance.numIndices < 3 ||
        instance.stride < 12) return;

    const uint8_t* vertices = (const uint8_t*)instance.vertexBuffer;
    const uint16_t* indices = (const uint16_t*)instance.indexBuffer;
    const bool hasNormals = (geometry->flags & rw::Geometry::NORMALS) != 0;
    const bool hasPrelit = (geometry->flags & rw::Geometry::PRELIT) != 0;
    const uint32_t colorOffset = 12 + (hasNormals ? 12 : 0);
    const rw::RGBA materialColor = get_material_color(instance.material);

    auto localIndex = [&](uint32_t value, uint32_t& result, uint32_t& sourceIndex) {
        if (value >= instance.minVert &&
            value - instance.minVert < (uint32_t)instance.numVertices) {
            result = value - instance.minVert;
            sourceIndex = value;
            return true;
        }
        if (value < (uint32_t)instance.numVertices) {
            result = value;
            sourceIndex = value + instance.minVert;
            return true;
        }
        return false;
    };

    auto emit = [&](uint32_t ia, uint32_t ib, uint32_t ic) {
        uint32_t a = 0, b = 0, c = 0;
        uint32_t sourceA = 0, sourceB = 0, sourceC = 0;
        if (!localIndex(ia, a, sourceA) ||
            !localIndex(ib, b, sourceB) ||
            !localIndex(ic, c, sourceC)) return;
        GtaTriangle triangle;
        if (!read_native_vertex(vertices, (uint32_t)instance.stride, a, sourceA,
                                hasPrelit ? colorOffset : UINT32_MAX,
                                frame, scale, materialColor, geometry, skin,
                                skinBinding, triangle.v[0]) ||
            !read_native_vertex(vertices, (uint32_t)instance.stride, b, sourceB,
                                hasPrelit ? colorOffset : UINT32_MAX,
                                frame, scale, materialColor, geometry, skin,
                                skinBinding, triangle.v[1]) ||
            !read_native_vertex(vertices, (uint32_t)instance.stride, c, sourceC,
                                hasPrelit ? colorOffset : UINT32_MAX,
                                frame, scale, materialColor, geometry, skin,
                                skinBinding, triangle.v[2])) return;
        if (triangles.size() < GTA_MAX_TRIANGLES) triangles.push_back(triangle);
    };

    if (instance.primType == 5) {
        for (uint32_t i = 0; i + 2 < (uint32_t)instance.numIndices; ++i) {
            if (i & 1) emit(indices[i + 1], indices[i], indices[i + 2]);
            else emit(indices[i], indices[i + 1], indices[i + 2]);
        }
    } else {
        for (uint32_t i = 0; i + 2 < (uint32_t)instance.numIndices; i += 3) {
            emit(indices[i], indices[i + 1], indices[i + 2]);
        }
    }
}

void append_geometry(std::vector<GtaTriangle>& triangles,
                     std::vector<GtaSkinBinding>& bindings,
                     rw::HAnimHierarchy* fallbackHierarchy,
                     rw::Atomic* atomic, float scale) {
    if (!atomic || !atomic->geometry) return;
    rw::Geometry* geometry = atomic->geometry;
    rw::Frame* frame = atomic->getFrame();
    rw::Skin* skin = rw::Skin::get(geometry);
    const uint32_t skinBinding =
        create_skin_binding(bindings, atomic, geometry, fallbackHierarchy);

    if (geometry->instData &&
        geometry->instData->platform == rw::PLATFORM_D3D8) {
        const rw::d3d8::InstanceDataHeader* header =
            (const rw::d3d8::InstanceDataHeader*)geometry->instData;
        if (!header->inst || header->numMeshes == 0) return;
        for (uint32_t mesh = 0; mesh < header->numMeshes; ++mesh) {
            append_native_mesh(triangles, header->inst[mesh], geometry, frame,
                               skin, skinBinding, scale);
        }
        return;
    }

    if (!geometry->morphTargets ||
        !geometry->morphTargets[0].vertices ||
        !geometry->triangles) return;

    for (int32_t i = 0; i < geometry->numTriangles; ++i) {
        const rw::Triangle& triangle = geometry->triangles[i];
        const uint16_t ia = triangle.v[0];
        const uint16_t ib = triangle.v[1];
        const uint16_t ic = triangle.v[2];
        if (ia >= geometry->numVertices || ib >= geometry->numVertices ||
            ic >= geometry->numVertices) continue;

        rw::Material* material = nullptr;
        if (triangle.matId < geometry->matList.numMaterials &&
            geometry->matList.materials) {
            material = geometry->matList.materials[triangle.matId];
        }
        const rw::RGBA materialColor = get_material_color(material);
        const rw::RGBA* ca = ((geometry->flags & rw::Geometry::PRELIT) && geometry->colors)
                                 ? &geometry->colors[ia] : nullptr;
        const rw::RGBA* cb = ((geometry->flags & rw::Geometry::PRELIT) && geometry->colors)
                                 ? &geometry->colors[ib] : nullptr;
        const rw::RGBA* cc = ((geometry->flags & rw::Geometry::PRELIT) && geometry->colors)
                                 ? &geometry->colors[ic] : nullptr;
        append_triangle(triangles,
                        geometry->morphTargets[0].vertices[ia],
                        geometry->morphTargets[0].vertices[ib],
                        geometry->morphTargets[0].vertices[ic],
                        frame, scale, materialColor, ca, cb, cc,
                        geometry, skin, skinBinding, ia, ib, ic);
    }
}

s16 clamp_vertex_coordinate(float value) {
    if (!std::isfinite(value)) return 0;
    if (value > 32767.0f) return 32767;
    if (value < -32768.0f) return -32768;
    return (s16)std::lround(value);
}

void update_gta_model_vertices(GtaModelState* state) {
    if (!state) return;

    // Build each inverse-bind * current-bone matrix once per bone, not once per vertex.
    for (GtaSkinBinding& binding : state->skinBindings) {
        const size_t boneCount = binding.boneFrames.size();
        binding.skinMatrices.resize(boneCount);
        binding.validSkinMatrices.assign(boneCount, 0);
        if (!binding.skin || !binding.skin->inverseMatrices) continue;

        for (size_t bone = 0; bone < boneCount; ++bone) {
            rw::Frame* boneFrame = binding.boneFrames[bone];
            if (!boneFrame) continue;
            const rw::Matrix* inverseBind =
                reinterpret_cast<const rw::Matrix*>(
                    binding.skin->inverseMatrices + bone * 16);
            rw::Matrix::mult(&binding.skinMatrices[bone],
                             inverseBind, boneFrame->getLTM());
            binding.validSkinMatrices[bone] = 1;
        }
    }

    for (GtaTriangle& triangle : state->triangles) {
        for (GtaVertex& vertex : triangle.v) {
            if (!vertex.target) continue;
            rw::V3d world = vertex.sourcePosition;
            bool skinned = false;

            if (vertex.skinBinding < state->skinBindings.size()) {
                const GtaSkinBinding& binding = state->skinBindings[vertex.skinBinding];
                if (binding.skin) {
                    rw::V3d accumulated = { 0.0f, 0.0f, 0.0f };
                    float totalWeight = 0.0f;
                    for (uint32_t influence = 0; influence < 4; ++influence) {
                        const uint8_t bone = vertex.boneIndices[influence];
                        const float weight = vertex.boneWeights[influence];
                        if (weight <= 0.00001f ||
                            bone >= binding.skinMatrices.size() ||
                            !binding.validSkinMatrices[bone]) continue;

                        const rw::Matrix& skinMatrix = binding.skinMatrices[bone];
                        rw::V3d transformed;
                        rw::V3d::transformPoints(&transformed, &vertex.sourcePosition, 1, &skinMatrix);
                        accumulated.x += transformed.x * weight;
                        accumulated.y += transformed.y * weight;
                        accumulated.z += transformed.z * weight;
                        totalWeight += weight;
                    }
                    if (totalWeight > 0.00001f) {
                        world.x = accumulated.x / totalWeight;
                        world.y = accumulated.y / totalWeight;
                        world.z = accumulated.z / totalWeight;
                        skinned = true;
                    }
                }
            }

            if (!skinned && vertex.staticFrame) {
                rw::V3d::transformPoints(&world, &vertex.sourcePosition, 1,
                                         vertex.staticFrame->getLTM());
            }

            // GTA SA is Z-up; SM64CoopDX is Y-up.
            vertex.target->l.x = clamp_vertex_coordinate(world.x * state->scale);
            vertex.target->l.y = clamp_vertex_coordinate(world.z * state->scale);
            vertex.target->l.z = clamp_vertex_coordinate(-world.y * state->scale);
            vertex.target->l.tu = 0;
            vertex.target->l.tv = 0;
            vertex.target->l.r = vertex.r;
            vertex.target->l.g = vertex.g;
            vertex.target->l.b = vertex.b;
            vertex.target->l.a = vertex.a;
        }
    }
}

void capture_gta_hierarchy(GtaModelState* state) {
    if (!state || !state->clump || !state->clump->getFrame()) return;
    state->hierarchy = rw::HAnimHierarchy::find(state->clump->getFrame());
    if (!state->hierarchy) return;
    state->hierarchy->attach();

    const size_t count = (size_t)state->hierarchy->numNodes;
    state->boneFrames.resize(count, nullptr);
    state->restMatrices.resize(count);
    for (size_t i = 0; i < count; ++i) {
        rw::Frame* frame = state->hierarchy->nodeInfo[i].frame;
        state->boneFrames[i] = frame;
        if (frame) {
            frame->getLTM();
            state->restMatrices[i] = frame->matrix;
        }
    }
}

void push_error(lua_State* Lvoid push_error(lua_State* L, const std::string& error) {
    lua_pushnil(L);
    lua_pushstring(L, error.c_str());
}

void push_img_table(lua_State* L, const std::string& path) {
    std::vector<ImgEntry> entries;
    std::string error;
    if (!parse_img_v2(path, entries, error)) {
        push_error(L, error);
        return;
    }

    lua_createtable(L, 0, 3);
    lua_pushinteger(L, 2);
    lua_setfield(L, -2, "version");
    lua_pushinteger(L, (lua_Integer)entries.size());
    lua_setfield(L, -2, "count");

    lua_createtable(L, (int)std::min<size_t>(entries.size(), 128), 0);
    const size_t count = std::min<size_t>(entries.size(), 128);
    for (size_t i = 0; i < count; ++i) {
        lua_pushstring(L, entries[i].name.c_str());
        lua_rawseti(L, -2, (int)i + 1);
    }
    lua_setfield(L, -2, "entries");
}

bool take_ifp_section(const uint8_t* bytes, size_t length, size_t& offset,
                      const char* expected, const uint8_t*& payload,
                      uint32_t& payloadLength) {
    if (offset > length || length - offset < 8) return false;
    if (expected && std::memcmp(bytes + offset, expected, 4) != 0) return false;
    payloadLength = read_u32_le(bytes + offset + 4);
    const uint64_t padded = ((uint64_t)payloadLength + 3ULL) & ~3ULL;
    if (padded > length - offset - 8) return false;
    payload = bytes + offset + 8;
    offset += 8 + (size_t)padded;
    return true;
}

std::string read_fixed_name(const uint8_t* p, size_t size) {
    size_t length = 0;
    while (length < size && p[length] != 0) ++length;
    return std::string(reinterpret_cast<const char*>(p), length);
}


std::string normalize_sa_bone_name(const std::string& name) {
    std::string normalized;
    normalized.reserve(name.size());
    for (unsigned char ch : name) {
        if (!std::isspace(ch)) {
            normalized.push_back((char)std::tolower(ch));
        }
    }
    return normalized;
}

int32_t resolve_sa_bone_id_from_name(const std::string& name) {
    struct BoneNameTag { const char* name; int32_t id; };
    static const BoneNameTag tags[] = {
        { "root", 0 }, { "normal", 0 },
        { "pelvis", 1 }, { "spine", 2 }, { "spine1", 3 },
        { "neck", 4 }, { "head", 5 },
        { "lbrow", 6 }, { "leftbrow", 6 },
        { "rbrow", 7 }, { "rightbrow", 7 },
        { "jaw", 8 },
        { "bip01rclavicle", 21 }, { "rclavicle", 21 }, { "rightclavicle", 21 },
        { "rupperarm", 22 }, { "rightupperarm", 22 },
        { "rforearm", 23 }, { "rightforearm", 23 },
        { "rhand", 24 }, { "righthand", 24 },
        { "rfingers", 25 }, { "rfinger", 25 }, { "rightfinger", 25 },
        { "rfinger01", 26 }, { "rightfinger01", 26 },
        { "bip01lclavicle", 31 }, { "lclavicle", 31 }, { "leftclavicle", 31 },
        { "lupperarm", 32 }, { "leftupperarm", 32 },
        { "lforearm", 33 }, { "leftforearm", 33 },
        { "lhand", 34 }, { "lefthand", 34 },
        { "lfingers", 35 }, { "lfinger", 35 }, { "leftfinger", 35 },
        { "lfinger01", 36 }, { "leftfinger01", 36 },
        { "lthigh", 41 }, { "leftthigh", 41 },
        { "lcalf", 42 }, { "leftcalf", 42 },
        { "lfoot", 43 }, { "leftfoot", 43 },
        { "ltoe", 44 }, { "ltoe0", 44 }, { "lefttoe", 44 },
        { "rthigh", 51 }, { "rightthigh", 51 },
        { "rcalf", 52 }, { "rightcalf", 52 },
        { "rfoot", 53 }, { "rightfoot", 53 },
        { "rtoe", 54 }, { "rtoe0", 54 }, { "righttoe", 54 },
        { "belly", 201 },
        { "rbreast", 301 }, { "rightbreast", 301 },
        { "lbreast", 302 }, { "leftbreast", 302 }
    };

    const std::string normalized = normalize_sa_bone_name(name);
    for (const BoneNameTag& tag : tags) {
        if (normalized == tag.name) return tag.id;
    }
    return -1;
}

bool parse_ifp_anp3(const std::vector<uint8_t>& bytes, IfpInfo& info,
                    std::string& error) {
    if (bytes.size() < 36 || std::memcmp(bytes.data(), "ANP3", 4) != 0) {
        error = "Cabecera ANP3 inválida.";
        return false;
    }
    const uint32_t declaredSize = read_u32_le(bytes.data() + 4);
    const uint64_t limit64 = 8ULL + declaredSize;
    if (limit64 > bytes.size() || limit64 < 36) {
        error = "Tamaño ANP3 fuera de los límites del recurso.";
        return false;
    }

    const size_t limit = (size_t)limit64;
    info.version = "ANP3";
    info.internalName = read_fixed_name(bytes.data() + 8, 24);
    const uint32_t animationCount = read_u32_le(bytes.data() + 32);
    if (animationCount > 10000) {
        error = "ANP3 contiene demasiadas animaciones.";
        return false;
    }

    size_t offset = 36;
    info.animations.clear();
    uint64_t totalFrameBytes = 0;
    uint64_t totalFrames = 0;

    for (uint32_t i = 0; i < animationCount; ++i) {
        if (offset > limit || limit - offset < 36) {
            error = "Tabla de animaciones ANP3 truncada.";
            return false;
        }

        IfpAnimationInfo animation;
        animation.name = read_fixed_name(bytes.data() + offset, 24);
        const uint32_t trackCount = read_u32_le(bytes.data() + offset + 24);
        const uint32_t declaredFramesSize = read_u32_le(bytes.data() + offset + 28);
        offset += 36;
        if (trackCount > 10000) {
            error = "ANP3 contiene demasiados tracks en una animación.";
            return false;
        }

        animation.tracks = trackCount;
        animation.trackData.reserve(trackCount);
        uint64_t animationFrameBytes = 0;

        for (uint32_t trackIndex = 0; trackIndex < trackCount; ++trackIndex) {
            if (offset > limit || limit - offset < 36) {
                error = "Track ANP3 truncado.";
                return false;
            }

            IfpTrack track;
            track.name = read_fixed_name(bytes.data() + offset, 24);
            track.frameType = read_u32_le(bytes.data() + offset + 24);
            const uint32_t frameCount = read_u32_le(bytes.data() + offset + 28);
            track.sourceBoneId = (int32_t)read_u32_le(bytes.data() + offset + 32);
            track.boneId = track.sourceBoneId >= 0
                               ? track.sourceBoneId
                               : resolve_sa_bone_id_from_name(track.name);
            track.sourceIndex = trackIndex;
            offset += 36;

            uint32_t frameSize = 0;
            switch (track.frameType) {
                case 1: frameSize = 20; break;
                case 2: frameSize = 32; break;
                case 3: frameSize = 10; break;
                case 4: frameSize = 16; break;
                default:
                    error = "Tipo de frame ANP3 no reconocido.";
                    return false;
            }

            const uint64_t frameBytes = (uint64_t)frameCount * frameSize;
            if (frameBytes > limit - offset || frameBytes > GTA_MAX_FILE_BYTES ||
                totalFrames + frameCount > 1000000ULL) {
                error = "Datos de frames ANP3 fuera de los límites.";
                return false;
            }

            track.keyFrames.reserve(frameCount);
            for (uint32_t frameIndex = 0; frameIndex < frameCount; ++frameIndex) {
                const uint8_t* data = bytes.data() + offset + (size_t)frameIndex * frameSize;
                IfpKeyFrame key;

                if (track.frameType == 1 || track.frameType == 2) {
                    key.rotation.x = read_f32_le(data + 0);
                    key.rotation.y = read_f32_le(data + 4);
                    key.rotation.z = read_f32_le(data + 8);
                    key.rotation.w = read_f32_le(data + 12);
                    key.time = read_f32_le(data + 16);
                    if (track.frameType == 2) {
                        key.translation.x = read_f32_le(data + 20);
                        key.translation.y = read_f32_le(data + 24);
                        key.translation.z = read_f32_le(data + 28);
                        key.hasTranslation = true;
                    }
                } else {
                    key.rotation.x = (float)read_i16_le(data + 0) / 4096.0f;
                    key.rotation.y = (float)read_i16_le(data + 2) / 4096.0f;
                    key.rotation.z = (float)read_i16_le(data + 4) / 4096.0f;
                    key.rotation.w = (float)read_i16_le(data + 6) / 4096.0f;
                    key.time = (float)read_i16_le(data + 8) / 60.0f;
                    if (track.frameType == 4) {
                        key.translation.x = (float)read_i16_le(data + 10) / 4096.0f;
                        key.translation.y = (float)read_i16_le(data + 12) / 4096.0f;
                        key.translation.z = (float)read_i16_le(data + 14) / 4096.0f;
                        key.hasTranslation = true;
                    }
                }

                if (!std::isfinite(key.time)) {
                    error = "ANP3 contiene un tiempo de keyframe inválido.";
                    return false;
                }
                animation.duration = std::max(animation.duration, key.time);
                track.keyFrames.push_back(key);
            }

            offset += (size_t)frameBytes;
            animationFrameBytes += frameBytes;
            animation.frames += frameCount;
            totalFrames += frameCount;
            animation.trackData.push_back(track);
        }

        if (animationFrameBytes != declaredFramesSize) {
            error = "El tamaño declarado de frames ANP3 no coincide con sus tracks.";
            return false;
        }
        totalFrameBytes += animationFrameBytes;
        info.animations.push_back(animation);
    }

    if (offset > limit || totalFrameBytes > GTA_MAX_FILE_BYTES) {
        error = "Estructura ANP3 inválida.";
        return false;
    }
    return true;
}

bool parse_ifp_anpk(const std::vector<uint8_t>& bytes, IfpInfo& info,
                    std::string& error) {
    if (bytes.size() < 16 || std::memcmp(bytes.data(), "ANPK", 4) != 0) {
        error = "Cabecera ANPK inválida.";
        return false;
    }

    const uint32_t declaredSize = read_u32_le(bytes.data() + 4);
    const uint64_t limit64 = 8ULL + declaredSize;
    if (limit64 > bytes.size() || limit64 < 16) {
        error = "Tamaño ANPK fuera de los límites del recurso.";
        return false;
    }

    const size_t limit = (size_t)limit64;
    size_t offset = 8;
    const uint8_t* infoData = nullptr;
    uint32_t infoLength = 0;
    if (!take_ifp_section(bytes.data(), limit, offset, "INFO", infoData, infoLength) ||
        infoLength < 4) {
        error = "Sección INFO ANPK inválida.";
        return false;
    }

    const uint32_t animationCount = read_u32_le(infoData);
    if (animationCount > 10000) {
        error = "ANPK contiene demasiadas animaciones.";
        return false;
    }

    info.version = "ANPK";
    info.internalName = read_fixed_name(infoData + 4, infoLength - 4);
    info.animations.clear();
    uint64_t totalFrames = 0;

    for (uint32_t i = 0; i < animationCount; ++i) {
        const uint8_t* nameData = nullptr;
        const uint8_t* dganData = nullptr;
        uint32_t nameLength = 0;
        uint32_t dganLength = 0;
        if (!take_ifp_section(bytes.data(), limit, offset, "NAME", nameData, nameLength) ||
            !take_ifp_section(bytes.data(), limit, offset, "DGAN", dganData, dganLength)) {
            error = "Sección NAME/DGAN ANPK truncada.";
            return false;
        }

        IfpAnimationInfo animation;
        animation.name = read_fixed_name(nameData, nameLength);
        size_t dganOffset = 0;
        const uint8_t* animInfo = nullptr;
        uint32_t animInfoLength = 0;
        if (!take_ifp_section(dganData, dganLength, dganOffset, "INFO",
                              animInfo, animInfoLength) || animInfoLength < 4) {
            error = "INFO interno de DGAN inválido.";
            return false;
        }

        const uint32_t trackCount = read_u32_le(animInfo);
        if (trackCount > 10000) {
            error = "ANPK contiene demasiados tracks.";
            return false;
        }
        animation.tracks = trackCount;
        animation.trackData.reserve(trackCount);

        for (uint32_t trackIndex = 0; trackIndex < trackCount; ++trackIndex) {
            const uint8_t* cpanData = nullptr;
            uint32_t cpanLength = 0;
            if (!take_ifp_section(dganData, dganLength, dganOffset, "CPAN",
                                  cpanData, cpanLength)) {
                error = "Sección CPAN ANPK truncada.";
                return false;
            }

            size_t cpanOffset = 0;
            const uint8_t* animData = nullptr;
            uint32_t animDataLength = 0;
            if (!take_ifp_section(cpanData, cpanLength, cpanOffset, "ANIM",
                                  animData, animDataLength) ||
                (animDataLength != 40 && animDataLength != 44 && animDataLength != 48)) {
                error = "Sección ANIM ANPK inválida.";
                return false;
            }

            IfpTrack track;
            track.name = read_fixed_name(animData, 24);
            track.sourceIndex = trackIndex;
            const uint32_t frameCount = read_u32_le(animData + 28);
            track.sourceBoneId = animDataLength >= 44
                                     ? (int32_t)read_u32_le(animData + 40)
                                     : -1;
            track.boneId = track.sourceBoneId >= 0
                               ? track.sourceBoneId
                               : resolve_sa_bone_id_from_name(track.name);

            if (frameCount > 1000000U || totalFrames + frameCount > 1000000ULL) {
                error = "ANPK contiene demasiados keyframes.";
                return false;
            }

            if (frameCount) {
                if (cpanOffset > cpanLength || cpanLength - cpanOffset < 8) {
                    error = "Faltan keyframes en un track ANPK.";
                    return false;
                }

                const char* keyType = reinterpret_cast<const char*>(cpanData + cpanOffset);
                const uint8_t* keyData = nullptr;
                uint32_t keyLength = 0;
                if (!take_ifp_section(cpanData, cpanLength, cpanOffset, nullptr,
                                      keyData, keyLength)) {
                    error = "Sección de keyframes ANPK truncada.";
                    return false;
                }

                uint32_t frameSize = 0;
                if (std::memcmp(keyType, "KR00", 4) == 0) {
                    frameSize = 20;
                    track.frameType = 1;
                } else if (std::memcmp(keyType, "KRT0", 4) == 0) {
                    frameSize = 32;
                    track.frameType = 2;
                } else if (std::memcmp(keyType, "KRTS", 4) == 0) {
                    frameSize = 44;
                    track.frameType = 3;
                } else {
                    error = "Tipo de keyframe ANPK no compatible.";
                    return false;
                }

                if ((uint64_t)frameCount * frameSize != keyLength) {
                    error = "Longitud de keyframes ANPK incorrecta.";
                    return false;
                }

                track.keyFrames.reserve(frameCount);
                for (uint32_t frameIndex = 0; frameIndex < frameCount; ++frameIndex) {
                    const uint8_t* data = keyData + (size_t)frameIndex * frameSize;
                    IfpKeyFrame key;
                    key.rotation.x = -read_f32_le(data + 0);
                    key.rotation.y = -read_f32_le(data + 4);
                    key.rotation.z = -read_f32_le(data + 8);
                    key.rotation.w = read_f32_le(data + 12);

                    if (track.frameType >= 2) {
                        key.translation.x = read_f32_le(data + 16);
                        key.translation.y = read_f32_le(data + 20);
                        key.translation.z = read_f32_le(data + 24);
                        key.hasTranslation = true;
                    }
                    if (track.frameType == 3) {
                        key.scale.x = read_f32_le(data + 28);
                        key.scale.y = read_f32_le(data + 32);
                        key.scale.z = read_f32_le(data + 36);
                        key.hasScale = true;
                        key.time = read_f32_le(data + 40);
                    } else {
                        key.time = read_f32_le(data + (track.frameType == 2 ? 28 : 16));
                    }

                    if (!std::isfinite(key.time)) {
                        error = "ANPK contiene un tiempo de keyframe inválido.";
                        return false;
                    }
                    animation.duration = std::max(animation.duration, key.time);
                    track.keyFrames.push_back(key);
                }
            }

            animation.frames += frameCount;
            totalFrames += frameCount;
            animation.trackData.push_back(track);
        }
        info.animations.push_back(animation);
    }
    return true;
}

bool parse_ifp(const std::vector<uint8_t>& bytes, IfpInfo& info,
               std::string& error) {
    if (bytes.size() < 4) {
        error = "Archivo IFP vacío o truncado.";
        return false;
    }
    if (std::memcmp(bytes.data(), "ANP3", 4) == 0) {
        return parse_ifp_anp3(bytes, info, error);
    }
    if (std::memcmp(bytes.data(), "ANPK", 4) == 0) {
        return parse_ifp_anpk(bytes, info, error);
    }
    error = "Formato IFP no reconocido: se esperaba ANP3 o ANPK.";
    return false;
}

GtaModelState* find_gta_model(uint32_t modelId) {
    for (GtaModelState* state : sGtaModels) {
        if (state && state->modelId == modelId) return state;
    }
    return nullptr;
}

int32_t find_hanim_node_by_id(const GtaModelState* state, int32_t boneId) {
    if (!state || !state->hierarchy || boneId < 0) return -1;
    for (int32_t node = 0; node < state->hierarchy->numNodes; ++node) {
        if (state->hierarchy->nodeInfo[node].id == boneId &&
            node < (int32_t)state->boneFrames.size() &&
            state->boneFrames[(size_t)node]) {
            return node;
        }
    }
    return -1;
}

void map_ifp_tracks(GtaModelState* state, IfpAnimationInfo& animation) {
    if (!state || !state->hierarchy) return;
    const int32_t nodeCount = state->hierarchy->numNodes;
    std::vector<bool> used((size_t)nodeCount, false);
    animation.matchedById = 0;
    animation.mappedByOrder = 0;

    for (IfpTrack& track : animation.trackData) {
        track.targetNode = -1;
        if (track.keyFrames.empty()) continue;

        int32_t node = find_hanim_node_by_id(state, track.boneId);
        if (node >= 0 && !used[(size_t)node]) {
            track.targetNode = node;
            used[(size_t)node] = true;
            animation.matchedById++;
            continue;
        }

        if (nodeCount <= 0) continue;
        const size_t sourceCount = std::max<size_t>(1, animation.trackData.size());
        int32_t candidate = (int32_t)(((uint64_t)track.sourceIndex *
                                       (uint64_t)nodeCount) / sourceCount);
        if (candidate >= nodeCount) candidate = nodeCount - 1;

        int32_t selected = -1;
        for (int32_t distance = 0; distance < nodeCount && selected < 0; ++distance) {
            const int32_t left = candidate - distance;
            const int32_t right = candidate + distance;
            if (left >= 0 && left < nodeCount && !used[(size_t)left] &&
                state->boneFrames[(size_t)left]) selected = left;
            if (selected < 0 && right >= 0 && right < nodeCount &&
                !used[(size_t)right] && state->boneFrames[(size_t)right]) selected = right;
        }
        if (selected >= 0) {
            track.targetNode = selected;
            used[(size_t)selected] = true;
            animation.mappedByOrder++;
        }
    }
}

IfpKeyFrame sample_ifp_track(const IfpTrack& track, float time) {
    if (track.keyFrames.empty()) return IfpKeyFrame();
    if (time <= track.keyFrames.front().time) return track.keyFrames.front();
    if (time >= track.keyFrames.back().time) return track.keyFrames.back();

    for (size_t i = 1; i < track.keyFrames.size(); ++i) {
        const IfpKeyFrame& next = track.keyFrames[i];
        if (time > next.time) continue;
        const IfpKeyFrame& previous = track.keyFrames[i - 1];
        const float span = next.time - previous.time;
        const float alpha = span > 0.000001f
                                ? std::max(0.0f, std::min(1.0f, (time - previous.time) / span))
                                : 0.0f;
        IfpKeyFrame result;
        result.rotation = rw::slerp(previous.rotation, next.rotation, alpha);
        result.translation.x = previous.translation.x +
            (next.translation.x - previous.translation.x) * alpha;
        result.translation.y = previous.translation.y +
            (next.translation.y - previous.translation.y) * alpha;
        result.translation.z = previous.translation.z +
            (next.translation.z - previous.translation.z) * alpha;
        result.scale.x = previous.scale.x + (next.scale.x - previous.scale.x) * alpha;
        result.scale.y = previous.scale.y + (next.scale.y - previous.scale.y) * alpha;
        result.scale.z = previous.scale.z + (next.scale.z - previous.scale.z) * alpha;
        result.time = time;
        result.hasTranslation = previous.hasTranslation || next.hasTranslation;
        result.hasScale = previous.hasScale || next.hasScale;
        return result;
    }
    return track.keyFrames.back();
}

bool apply_gta_animation(GtaModelState* state) {
    if (!state || !state->hierarchy || state->activeAnimation < 0 ||
        (size_t)state->activeAnimation >= state->animations.size()) return false;

    IfpAnimationInfo& animation = state->animations[(size_t)state->activeAnimation];
    for (size_t i = 0; i < state->boneFrames.size(); ++i) {
        rw::Frame* frame = state->boneFrames[i];
        if (frame && i < state->restMatrices.size()) {
            frame->transform(&state->restMatrices[i], rw::COMBINEREPLACE);
        }
    }

    float animationTime = state->animationTime;
    if (animation.duration > 0.0001f) {
        animationTime = std::fmod(animationTime, animation.duration);
    } else {
        animationTime = 0.0f;
    }

    for (IfpTrack& track : animation.trackData) {
        if (track.targetNode < 0 ||
            (size_t)track.targetNode >= state->boneFrames.size() ||
            track.keyFrames.empty()) continue;

        rw::Frame* frame = state->boneFrames[(size_t)track.targetNode];
        if (!frame || (size_t)track.targetNode >= state->restMatrices.size()) continue;
        const IfpKeyFrame key = sample_ifp_track(track, animationTime);
        const rw::Matrix& rest = state->restMatrices[(size_t)track.targetNode];
        rw::Matrix local = rest;
        rw::Matrix animatedRotation;
        animatedRotation.setIdentity();

        rw::Quat rotation = key.rotation;
        if (rw::normsq(rotation) > 0.000001f) {
            rotation = rw::normalize(rotation);
        } else {
            rotation = rw::makeQuat(1.0f, 0.0f, 0.0f, 0.0f);
        }
        animatedRotation.rotate(rotation, rw::COMBINEREPLACE);

        // IFP quaternions are absolute local rotations. Replace the rotation
        // while retaining the target bone's bind-pose translation and scale.
        local.right = rw::scale(animatedRotation.right, rw::length(rest.right));
        local.up = rw::scale(animatedRotation.up, rw::length(rest.up));
        local.at = rw::scale(animatedRotation.at, rw::length(rest.at));

        // Root translation is an absolute local channel, not a delta from bind pose.
        local.pos = key.hasTranslation ? key.translation : rest.pos;
        if (key.hasScale) {
            local.scale(&key.scale, rw::COMBINEPOSTCONCAT);
        }
        frame->transform(&local, rw::COMBINEREPLACE);
    }

    if (state->clump && state->clump->getFrame()) {
        state->clump->getFrame()->syncHierarchyLTM();
    }
    update_gta_model_vertices(state);
    return true;
}

bool create_dynos_model(GtaModelState* state,
                        uint32_t& modelId, std::string& error) {
    if (!gLuaActiveMod) {
        error = "El modelo debe cargarse desde el contexto de un mod Lua.";
        return false;
    }
    if (!state || state->triangles.empty()) {
        error = "El DFF no contiene geometría renderizable compatible.";
        return false;
    }

    const uint32_t serial = ++sGtaModelSerial;
    const size_t partCount =
        (state->triangles.size() + GTA_TRIANGLES_PER_PART - 1) / GTA_TRIANGLES_PER_PART;
    std::vector<Gfx*> parts;
    parts.reserve(partCount);

    for (size_t part = 0; part < partCount; ++part) {
        const size_t first = part * GTA_TRIANGLES_PER_PART;
        const size_t count = std::min(GTA_TRIANGLES_PER_PART, state->triangles.size() - first);
        char name[96];

        std::snprintf(name, sizeof(name), "gta_sa_%u_vtx_%zu", serial, part);
        Vtx* vertices = DynOS_Vtx_Create(name, (u32)(count * 3));
        if (!vertices) {
            error = "DynOS no pudo reservar el buffer de vértices para el modelo GTA.";
            return false;
        }

        for (size_t i = 0; i < count; ++i) {
            for (size_t j = 0; j < 3; ++j) {
                GtaVertex& source = state->triangles[first + i].v[j];
                Vtx& target = vertices[i * 3 + j];
                source.target = &target;
                target.l.x = 0;
                target.l.y = 0;
                target.l.z = 0;
                target.l.tu = 0;
                target.l.tv = 0;
                target.l.r = source.r;
                target.l.g = source.g;
                target.l.b = source.b;
                target.l.a = source.a;
            }
        }

        std::snprintf(name, sizeof(name), "gta_sa_%u_part_%zu", serial, part);
        Gfx* displayList = DynOS_Gfx_Create(name, (u32)(count * 2 + 1));
        if (!displayList) {
            error = "DynOS no pudo reservar una lista de dibujo para el modelo GTA.";
            return false;
        }
        for (size_t i = 0; i < count; ++i) {
            displayList[i * 2 + 0] = gsSPVertex(&vertices[i * 3], 3, 0);
            displayList[i * 2 + 1] = gsSP1Triangle(0, 1, 2, 0);
        }
        displayList[count * 2] = gsSPEndDisplayList();
        parts.push_back(displayList);
    }

    char rootName[96];
    std::snprintf(rootName, sizeof(rootName), "gta_sa_%u_root", serial);
    Gfx* root = DynOS_Gfx_Create(rootName, (u32)(parts.size() + 3));
    if (!root) {
        error = "DynOS no pudo reservar la lista raíz del modelo GTA.";
        return false;
    }
    root[0] = gsDPSetCombineMode(G_CC_SHADE, G_CC_SHADE);
    root[1] = gsSPClearGeometryMode(G_LIGHTING);
    for (size_t i = 0; i < parts.size(); ++i) {
        root[i + 2] = gsSPDisplayList(parts[i]);
    }
    root[parts.size() + 2] = gsSPEndDisplayList();

    modelId = 0;
    if (!DynOS_Model_LoadDl(&modelId, MODEL_POOL_SESSION, 1, root)) {
        error = "SM64CoopDX rechazó el display list generado para el DFF.";
        return false;
    }

    state->modelId = modelId;
    sGtaModels.push_back(state);
    update_gta_model_vertices(state);
    return true;
}


} // namespace

extern "C" int gta_sa_lua_scan_img(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    if (!path) return 0;
    std::vector<ImgEntry> entries;
    std::string error;
    if (!parse_img_v2(path, entries, error)) {
        push_error(L, error);
        return 2;
    }
    lua_createtable(L, 0, 3);
    lua_pushinteger(L, 2);
    lua_setfield(L, -2, "version");
    lua_pushinteger(L, (lua_Integer)entries.size());
    lua_setfield(L, -2, "count");
    lua_createtable(L, (int)std::min<size_t>(entries.size(), 128), 0);
    const size_t count = std::min<size_t>(entries.size(), 128);
    for (size_t i = 0; i < count; ++i) {
        lua_pushstring(L, entries[i].name.c_str());
        lua_rawseti(L, -2, (int)i + 1);
    }
    lua_setfield(L, -2, "entries");
    return 1;
}

extern "C" int gta_sa_lua_load_dff(lua_State* L) {
    const int argc = lua_gettop(L);
    if (argc != 3 && argc != 5) {
        push_error(L, "Uso: gta_sa_load_dff(imgPath, dffEntry, scale[, txdImgPath, txdEntry])");
        return 2;
    }

    const char* imgPathValue = luaL_checkstring(L, 1);
    const char* dffEntryValue = luaL_checkstring(L, 2);
    const float scale = (float)luaL_optnumber(L, 3, 100.0);
    if (!imgPathValue || !dffEntryValue || !std::isfinite(scale) ||
        scale <= 0.0f || scale > 10000.0f) {
        push_error(L, "Ruta, entrada DFF o escala inválida.");
        return 2;
    }

    const std::string imgPath(imgPathValue);
    const std::string dffEntry(dffEntryValue);
    std::string error;

    if (argc == 5) {
        const char* txdPath = luaL_checkstring(L, 4);
        const char* txdEntry = luaL_checkstring(L, 5);
        if (!txdPath || !txdEntry ||
            !load_txd_from_img(txdPath, txdEntry, error)) {
            push_error(L, error.empty() ? "No se pudo cargar el TXD." : error);
            return 2;
        }
    } else if (!ensure_renderware()) {
        push_error(L, "No se pudo iniciar RenderWare.");
        return 2;
    }

    std::vector<uint8_t> bytes;
    if (!read_img_entry(imgPath, dffEntry, bytes, error)) {
        push_error(L, error);
        return 2;
    }

    rw::StreamMemory stream;
    stream.open(bytes.data(), (uint32_t)bytes.size());
    uint32_t chunkLength = 0, version = 0;
    if (!rw::findChunk(&stream, rw::ID_CLUMP, &chunkLength, &version)) {
        push_error(L, "La entrada DFF no contiene un clump RenderWare válido.");
        return 2;
    }
    rw::Clump* clump = rw::Clump::streamRead(&stream);
    if (!clump) {
        push_error(L, "librw no pudo interpretar la geometría del DFF.");
        return 2;
    }

    GtaModelState* state = new GtaModelState();
    state->clump = clump;
    state->scale = scale;
    if (clump->getFrame()) clump->getFrame()->syncHierarchyLTM();
    capture_gta_hierarchy(state);

    FORLIST(link, clump->atomics) {
        rw::Atomic* atomic = rw::Atomic::fromClump(link);
        append_geometry(state->triangles, state->skinBindings,
                        state->hierarchy, atomic, scale);
        if (state->triangles.size() >= GTA_MAX_TRIANGLES) break;
    }

    if (state->triangles.empty()) {
        clump->destroy();
        delete state;
        push_error(L, "El DFF se leyó, pero no se pudieron convertir sus geometrías. Puede usar skinning/nativo no soportado.");
        return 2;
    }

    uint32_t modelId = 0;
    if (!create_dynos_model(state, modelId, error)) {
        clump->destroy();
        delete state;
        push_error(L, error);
        return 2;
    }

    lua_pushinteger(L, (lua_Integer)modelId);
    lua_createtable(L, 0, 5);
    lua_pushinteger(L, (lua_Integer)state->triangles.size());
    lua_setfield(L, -2, "triangles");
    lua_pushinteger(L, (lua_Integer)state->triangles.size() * 3);
    lua_setfield(L, -2, "vertices");
    lua_pushnumber(L, scale);
    lua_setfield(L, -2, "scale");
    lua_pushinteger(L, state->hierarchy ? state->hierarchy->numNodes : 0);
    lua_setfield(L, -2, "bones");
    lua_pushinteger(L, (lua_Integer)state->skinBindings.size());
    lua_setfield(L, -2, "skinnedMeshes");
    return 2;
}

extern "C" int gta_sa_lua_load_ifp(lua_State* L) {
    const int argc = lua_gettop(L);
    if (argc != 2 && argc != 3) {
        push_error(L, "Uso: gta_sa_load_ifp(imgPath, ifpEntry[, modelId])");
        return 2;
    }
    const char* imgPath = luaL_checkstring(L, 1);
    const char* ifpEntry = luaL_checkstring(L, 2);
    if (!imgPath || !ifpEntry) return 0;

    GtaModelState* model = nullptr;
    if (argc == 3) {
        const lua_Integer requestedId = luaL_checkinteger(L, 3);
        if (requestedId <= 0 || requestedId > UINT32_MAX) {
            push_error(L, "modelId inválido.");
            return 2;
        }
        model = find_gta_model((uint32_t)requestedId);
        if (!model) {
            push_error(L, "No existe un modelo GTA cargado con ese modelId.");
            return 2;
        }
    }

    std::vector<uint8_t> bytes;
    std::string error;
    if (!read_img_entry(imgPath, ifpEntry, bytes, error)) {
        push_error(L, error);
        return 2;
    }

    IfpInfo info;
    if (!parse_ifp(bytes, info, error)) {
        push_error(L, error);
        return 2;
    }

    if (model) {
        model->animations = info.animations;
        model->activeAnimation = -1;
        model->animationTime = 0.0f;
    }

    const std::vector<IfpAnimationInfo>& animations =
        model ? model->animations : info.animations;
    lua_createtable(L, 0, 4);
    lua_pushstring(L, info.version.c_str());
    lua_setfield(L, -2, "version");
    lua_pushstring(L, info.internalName.c_str());
    lua_setfield(L, -2, "internalName");
    lua_pushinteger(L, model && model->hierarchy ? model->hierarchy->numNodes : 0);
    lua_setfield(L, -2, "targetBones");
    lua_createtable(L, (int)animations.size(), 0);
    for (size_t i = 0; i < animations.size(); ++i) {
        lua_createtable(L, 0, 4);
        lua_pushstring(L, animations[i].name.c_str());
        lua_setfield(L, -2, "name");
        lua_pushinteger(L, animations[i].tracks);
        lua_setfield(L, -2, "tracks");
        lua_pushinteger(L, animations[i].frames);
        lua_setfield(L, -2, "frames");
        lua_pushnumber(L, animations[i].duration);
        lua_setfield(L, -2, "duration");
        lua_rawseti(L, -2, (int)i + 1);
    }
    lua_setfield(L, -2, "animations");
    return 1;
}

extern "C" int gta_sa_lua_play_ifp(lua_State* L) {
    if (lua_gettop(L) != 2) {
        push_error(L, "Uso: gta_sa_play_ifp(modelId, animationName)");
        return 2;
    }
    const lua_Integer requestedId = luaL_checkinteger(L, 1);
    const char* animationName = luaL_checkstring(L, 2);
    if (requestedId <= 0 || requestedId > UINT32_MAX || !animationName) {
        push_error(L, "modelId o nombre de animación inválido.");
        return 2;
    }

    GtaModelState* model = find_gta_model((uint32_t)requestedId);
    if (!model) {
        push_error(L, "No existe un modelo GTA cargado con ese modelId.");
        return 2;
    }
    if (!model->hierarchy || model->boneFrames.empty()) {
        push_error(L, "El DFF no contiene una jerarquía HAnim utilizable.");
        return 2;
    }

    auto equalName = [](const std::string& a, const char* b) {
        if (!b || a.size() != std::strlen(b)) return false;
        for (size_t i = 0; i < a.size(); ++i) {
            if (std::tolower((unsigned char)a[i]) !=
                std::tolower((unsigned char)b[i])) return false;
        }
        return true;
    };

    for (size_t i = 0; i < model->animations.size(); ++i) {
        IfpAnimationInfo& animation = model->animations[i];
        if (!equalName(animation.name, animationName)) continue;
        map_ifp_tracks(model, animation);
        model->activeAnimation = (int32_t)i;
        model->animationTime = 0.0f;
        if (!apply_gta_animation(model)) {
            push_error(L, "No se pudo aplicar la animación al esqueleto DFF.");
            return 2;
        }

        lua_pushboolean(L, 1);
        lua_createtable(L, 0, 3);
        lua_pushinteger(L, animation.matchedById);
        lua_setfield(L, -2, "matchedById");
        lua_pushinteger(L, animation.mappedByOrder);
        lua_setfield(L, -2, "mappedByOrder");
        lua_pushinteger(L, animation.tracks -
                           animation.matchedById - animation.mappedByOrder);
        lua_setfield(L, -2, "unmappedTracks");
        return 2;
    }

    push_error(L, std::string("No existe la animación '") + animationName + "'.");
    return 2;
}

extern "C" int gta_sa_lua_update_ifp(lua_State* L) {
    if (lua_gettop(L) != 2) {
        push_error(L, "Uso: gta_sa_update_ifp(modelId, deltaSeconds)");
        return 2;
    }
    const lua_Integer requestedId = luaL_checkinteger(L, 1);
    const float delta = (float)luaL_checknumber(L, 2);
    if (requestedId <= 0 || requestedId > UINT32_MAX ||
        !std::isfinite(delta) || delta < 0.0f || delta > 1.0f) {
        push_error(L, "modelId o deltaSeconds fuera de rango.");
        return 2;
    }

    GtaModelState* model = find_gta_model((uint32_t)requestedId);
    if (!model || model->activeAnimation < 0) {
        push_error(L, "El modelo no tiene una animación IFP activa.");
        return 2;
    }
    model->animationTime += delta;
    if (!apply_gta_animation(model)) {
        push_error(L, "Falló la actualización de la animación IFP.");
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}
