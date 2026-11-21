-- Section-local invalidation for the voxel renderer.
-- Minecraft stores/render-compiles 16x16x16 block sections. A block edit
-- marks the section halo touched by the changed block and its immediate
-- neighbors; this helper mirrors that bookkeeping for SteveCraft's smaller
-- per-block mesh cache, without rebuilding unrelated parts of the world.

local SectionUpdates = {}
SectionUpdates.SECTION_SIZE = 16
SectionUpdates.NEIGHBORHOOD_RADIUS = 1

local function cell_key(x, y, z)
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

local function section_coord(value)
    return math.floor(value / SectionUpdates.SECTION_SIZE)
end

local function section_key(x, y, z)
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

function SectionUpdates.sections_for_edit(x, y, z)
    local seen = {}
    local result = {}
    local radius = SectionUpdates.NEIGHBORHOOD_RADIUS

    for dx = -radius, radius do
        for dy = -radius, radius do
            for dz = -radius, radius do
                local sx = section_coord(x + dx)
                local sy = section_coord(y + dy)
                local sz = section_coord(z + dz)
                local key = section_key(sx, sy, sz)
                if not seen[key] then
                    seen[key] = true
                    result[#result + 1] = { x = sx, y = sy, z = sz, key = key }
                end
            end
        end
    end

    table.sort(result, function(a, b) return a.key < b.key end)
    return result
end

function SectionUpdates.affected_cells(blocks, x, y, z)
    local result = {}
    local sections = SectionUpdates.sections_for_edit(x, y, z)
    local radius = SectionUpdates.NEIGHBORHOOD_RADIUS

    for dx = -radius, radius do
        for dy = -radius, radius do
            for dz = -radius, radius do
                local cx, cy, cz = x + dx, y + dy, z + dz
                local key = cell_key(cx, cy, cz)
                local cell = blocks and blocks[key] or nil
                if cell ~= nil then
                    result[#result + 1] = {
                        key = key,
                        x = cx,
                        y = cy,
                        z = cz,
                        cell = cell,
                        section_key = section_key(
                            section_coord(cx), section_coord(cy), section_coord(cz)
                        ),
                    }
                end
            end
        end
    end

    table.sort(result, function(a, b) return a.key < b.key end)
    return result, sections
end

function SectionUpdates.section_key(x, y, z)
    return section_key(section_coord(x), section_coord(y), section_coord(z))
end

return SectionUpdates
