local M = {}

local filename = "/settings/floodPresets.json"
local presets = {}

local function loadPresets()
    presets = jsonReadFile(filename)
    if not presets or #presets == 0 then
        presets = {}

        jsonWriteFile(filename, {}, false)
        return false
    end
    
    return true
end

local function getPresets()
    return presets
end

local function getPreset(name)
    for i, v in ipairs(presets) do
        if name == v.name then return deepcopy(v), i end
    end

    return nil
end

local function savePreset(name, data)
    disableFlood = disableFlood or true

    local preset = {
        name = name,
        data = shallowcopy(data)
    }

    local storedPreset, i = getPreset(name)
    if storedPreset then
        storedPreset = preset
    else
        i = #presets + 1
    end

    preset.data.enabled = false

    presets[i] = preset
    jsonWriteFile(filename, presets, false)

    return true
end

local function deletePreset(name)
    local _, i = getPreset(name)
    if not i then log('E', 'deletePreset', 'Cannot delete preset: ' .. tostring(name)) end

    local newPresets = {}
    for _, v in ipairs(presets) do
        if v.name == name then goto continue end
        newPresets[#newPresets + 1] = deepcopy(v)

        ::continue::
    end

    presets = newPresets
    jsonWriteFile(filename, presets, false)
end

-- Public Interface
------------------------------------------------------------
M.loadPresets  = loadPresets
M.getPresets   = getPresets
M.getPreset    = getPreset
M.savePreset   = savePreset
M.deletePreset = deletePreset

return M