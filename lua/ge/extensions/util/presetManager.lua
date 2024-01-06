local M = {}

M.defaults = {
    ["enabled"]              = false,
    ["speed"]                = 0.001,
    ["heightLimit"]          = 0,
    ["limitEnabled"]         = false,
    ["decrease"]             = false,
    ["gradualReturn"]        = false,
    ["hideCoveredWater"]     = true,
    ["stopWhenSubmerged"]    = false,
    ["floodWithRain"]        = false,
    ["rainMultiplier"]       = 0.01,
    ["rainEnabled"]          = false,
    ["rainVolume"]           = 0,
    ["rainAmount"]           = 0,
}

local filename = "/settings/floodPresets.json"
local presets = {}

local function validateAndUpdate(preset)
    local updated = false
    for dn, dv in pairs(M.defaults) do
        if preset.data[dn] == nil then
            log('W', 'validateAndUpdate', 'Updated preset \"' .. preset.name .. '\" with option: ' .. dn)
            preset.data[dn] = dv
            updated = true
        end
    end

    return preset, updated
end

local function writePresetsToFile()
    local copy = {}
    for _, v in ipairs(presets) do
        if v.name == "Default" then goto continue end
        copy[#copy + 1] = v
        
        ::continue::
    end

    jsonWriteFile(filename, copy, false)
end

local function loadPresets()
    presets[1] = {
        name = "Default",
        data = M.defaults
    }

    local filePresets = jsonReadFile(filename)

    if not filePresets then
        jsonWriteFile(filename, {}, false)
        return true
    else
        for i, v in ipairs(filePresets) do
            presets[i + 1] = v
        end

        local updated = false
        local invalidPresetFound = false

        for i, preset in ipairs(presets) do
            presets[i], updated = validateAndUpdate(preset, M.defaults)
            if updated then invalidPresetFound = true end
        end

        if invalidPresetFound then
            writePresetsToFile()
        end
    end
    
    return true
end

local function getPresets()
    return presets
end

local function getPreset(name)
    for i, v in ipairs(presets) do
        if name == v.name then
            local validated, updated = validateAndUpdate(v)
            if updated then
                writePresetsToFile()
            end

            return deepcopy(validated), i
        end
    end

    return nil
end

local function savePreset(name, data)
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
    writePresetsToFile()

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
    writePresetsToFile()
end

-- Public Interface
------------------------------------------------------------
M.loadPresets  = loadPresets
M.getPresets   = getPresets
M.getPreset    = getPreset
M.savePreset   = savePreset
M.deletePreset = deletePreset

return M