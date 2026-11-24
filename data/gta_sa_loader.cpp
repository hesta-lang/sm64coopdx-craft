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

rw::TexDictionary* sCurrentGtaTxdrw::TexDictionary* sCurrentGtaTxd = nullptr;
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
    for (GtaTriangle& triangle : state->triangles) {
        for (GtaVertex& vertex : triangle.v) {
            if (!vertex.target) continue;
            rw::V3d world = vertex.sourcePosition;
            bool skinned = false;

            if (vertex.skinBinding < state->skinBindings.size()) {
                const GtaSkinBinding& binding = state->skinBindings[vertex.skinBinding];
                if (binding.skin && binding.skin->inverseMatrices) {
                    rw::V3d accumulated = { 0.0f, 0.0f, 0.0f };
                    float totalWeight = 0.0f;
                    for (uint32_t influence = 0; influence < 4; ++influence) {
                        const uint8_t bone = vertex.boneIndices[influence];
                        const float weight = vertex.boneWeights[influence];
                        if (weight <= 0.00001f || bone >= binding.boneFrames.size()) continue;
                        rw::Frame* boneFrame = binding.boneFrames[bone];
                        if (!boneFrame) continue;

                        const rw::Matrix* inverseBind =
                            reinterpret_cast<const rw::Matrix*>(
                                binding.skin->inverseMatrices + (size_t)bone * 16);
                        rw::Matrix skinMatrix;
                        rw::Matrix::mult(&skinMatrix, inverseBind, boneFrame->getLTM());
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
            vertex.target->v.ob[0] = clamp_vertex_coordinate(world.x * state->scale);
            vertex.target->v.ob[1] = clamp_vertex_coordinate(world.z * state->scale);
            vertex.target->v.ob[2] = clamp_vertex_coordinate(-world.y * state->scale);
            vertex.target->v.tc[0] = 0;
            vertex.target->v.tc[1] = 0;
            vertex.target->v.cn[0] = vertex.r;
            vertex.target->v.cn[1] = vertex.g;
            vertex.target->v.cn[2] = vertex.b;
            vertex.target->v.cn[3] = vertex.a;
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
    uint32_t animationCount = read_u32_le(bytes.data() + 32);
    if (animationCount > 10000) {
        error = "ANP3 contiene demasiadas animaciones.";
        return false;
    }

    size_t offset = 36;
    info.animations.clear();
    uint64_t consumedFrameBytes = 0;
    for (uint32_t i = 0; i < animationCount; ++i) {
        if (offset > limit || limit - offset < 36) {
            error = "Tabla de animaciones ANP3 truncada.";
            return false;
        }
        IfpAnimationInfo animation;
        animation.name = read_fixed_name(bytes.data() + offset, 24);
        const uint32_t tracks = read_u32_le(bytes.data() + offset + 24);
        const uint32_t declaredFramesSize = read_u32_le(bytes.data() + offset + 28);
        offset += 36;
        if (tracks > 10000) {
            error = "ANP3 contiene demasiados tracks en una animación.";
            return false;
        }
        animation.tracks = tracks;
        uint64_t animationFrameBytes = 0;

        for (uint32_t track = 0; track < tracks; ++track) {
            if (offset > limit || limit - offset < 36) {
                error = "Track ANP3 truncado.";
                return false;
            }
            const uint32_t frameType = read_u32_le(bytes.data() + offset + 24);
            const uint32_t frameCount = read_u32_le(bytes.data() + offset + 28);
            offset += 36;

            uint32_t frameSize = 0;
            switch (frameType) {
                case 1: frameSize = 20; break; // child float
                case 2: frameSize = 32; break; // root float
                case 3: frameSize = 10; break; // child fixed-point
                case 4: frameSize = 16; break; // root fixed-point
                default:
                    error = "Tipo de frame ANP3 no reconocido.";
                    return false;
            }
            const uint64_t frameBytes = (uint64_t)frameCount * frameSize;
            if (frameBytes > limit - offset || frameBytes > GTA_MAX_FILE_BYTES) {
                error = "Datos de frames ANP3 fuera de los límites.";
                return false;
            }
            offset += (size_t)frameBytes;
            animationFrameBytes += frameBytes;
            animation.frames += frameCount;
        }

        if (animationFrameBytes != declaredFramesSize) {
            error = "El tamaño declarado de frames ANP3 no coincide con sus tracks.";
            return false;
        }
        consumedFrameBytes += animationFrameBytes;
        info.animations.push_back(animation);
    }
    if (offset > limit || consumedFrameBytes > GTA_MAX_FILE_BYTES) {
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

    for (uint32_t i = 0; i < animationCount; ++i) {
        const uint8_t* nameData = nullptr;
        const uint8_t* dganData = nullptr;
        uint32_t nameLength = 0, dganLength = 0;
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

        for (uint32_t track = 0; track < trackCount; ++track) {
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
                animDataLength < 40) {
                error = "Sección ANIM ANPK inválida.";
                return false;
            }

            const uint32_t frameCount = read_u32_le(animData + 28);
            animation.frames += frameCount;
            if (frameCount) {
                if (cpanOffset > cpanLength || cpanLength - cpanOffset < 8) {
                    error = "Faltan keyframes en un track ANPK.";
                    return false;
                }
                const char* keyType = reinterpret_cast<const char*>(cpanData + cpanOffset);
                const uint32_t keyLength = read_u32_le(cpanData + cpanOffset + 4);
                uint32_t frameSize = 0;
                if (std::memcmp(keyType, "KR00", 4) == 0) frameSize = 20;
                else if (std::memcmp(keyType, "KRT0", 4) == 0) frameSize = 32;
                else if (std::memcmp(keyType, "KRTS", 4) == 0) frameSize = 44;
                else {
                    error = "Tipo de keyframe ANPK no compatible.";
                    return false;
                }
                if ((uint64_t)frameCount * frameSize != keyLength ||
                    keyLength > cpanLength - cpanOffset - 8) {
                    error = "Longitud de keyframes ANPK incorrecta.";
                    return false;
                }
            }
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
                target.v.ob[0] = 0;
                target.v.ob[1] = 0;
                target.v.ob[2] = 0;
                target.v.tc[0] = 0;
                target.v.tc[1] = 0;
                target.v.cn[0] = source.r;
                target.v.cn[1] = source.g;
                target.v.cn[2] = source.b;
                target.v.cn[3] = source.a;
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
    if (lua_gettop(L) != 2) {
        push_error(L, "Uso: gta_sa_load_ifp(imgPath, ifpEntry)");
        return 2;
    }
    const char* imgPath = luaL_checkstring(L, 1);
    const char* ifpEntry = luaL_checkstring(L, 2);
    if (!imgPath || !ifpEntry) return 0;

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

    lua_createtable(L, 0, 3);
    lua_pushstring(L, info.version.c_str());
    lua_setfield(L, -2, "version");
    lua_pushstring(L, info.internalName.c_str());
    lua_setfield(L, -2, "internalName");
    lua_createtable(L, (int)info.animations.size(), 0);
    for (size_t i = 0; i < info.animations.size(); ++i) {
        lua_createtable(L, 0, 3);
        lua_pushstring(L, info.animations[i].name.c_str());
        lua_setfield(L, -2, "name");
        lua_pushinteger(L, info.animations[i].tracks);
        lua_setfield(L, -2, "tracks");
        lua_pushinteger(L, info.animations[i].frames);
        lua_setfield(L, -2, "frames");
        lua_rawseti(L, -2, (int)i + 1);
    }
    lua_setfield(L, -2, "animations");
    return 1;
}
