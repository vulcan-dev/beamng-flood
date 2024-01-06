local M = {}
local imgui = ui_imgui

-- TODO: Stop when submerged

local presetManager = require("util.presetManager")

-- Public Variables
------------------------------------------------------------
M.presetData = {}

M.showUI = imgui.BoolPtr(false)
M.maxSpeed = 50
M.ocean = nil

-- Private Variables
------------------------------------------------------------
local waterSources = {}

local defaultPresetName = "Default"
local activePreset = ""

local rainObj = nil
local inMission = false

local initialWaterPosition = nil
local hiddenWater = {} -- This is used for storing the water sources below the ocean leven (when hiding overlapped water sources).

local defaultWindowHeight = 430
local expandedWindowHeight = 480 -- When the rain category is open
local windowMinHeight = defaultWindowHeight
local shouldResetWindowHeight = false

local ptrWaterLevel = imgui.FloatPtr(0)
local displayHours = 0
local ptrHoursMilitary = imgui.FloatPtr(0)
local ptrMinutes = imgui.IntPtr(0)

local presetNameBuffer = imgui.ArrayChar(32)

local version = "1.4.0"
local changes = [[
    New Features/Changes:
      - Added this wonderful help menu
      - Added "Stop when submerged option", this stops the flooding once your vehicle has been submerged by the water
      - Changed "Enable" toggle to a Start/Stop Button
      - Reset button now disables flooding
      - When water reaches the heightLimit, it will now stop flooding
      - Changed max speed from 1 to 50 (also exposed it so you can modify it from the console `flood.maxSpeed = numberHere`)
      - Flood speed now respects bullet time (slow motion)
      - Made the UI look slightly better
      - Disabled UI elements when there is no ocean
      - Improved tooltips
      - Added presets, might be useful for flood maps with difficulty settings
      - You can now only select "Decrease" or "Gradual Return", you can't do both
      - Improved resizing window height when the rain section is hidden
        It will keep the size if you manually resized it, otherwise it will resize itself to fit the new content height

    Fixes:
      - I'm fairly certain I've fixed the "attempt to index global 'flood'" for some users, let's pray
      - Gradual Return will now decrease the water level to the precise starting position
      - Fixed flood with rain not functioning correctly (it didn't work when `Speed` was 0)
      - Fixed mission file changes, we now use `onClientStartMission` and `onClientEndMission` instead of checking in `onUpdate`
      - Time in environment options is now synced with the in-game time. I have also made it match the slider (time from 12 -> 0 -> 12) instead of 0-24
      - Renamed "Decrease to initial" to "Gradual Return"

    Changes I care about:
      - Removed skyColor and related functions, they never got used
      - Added comments to the code
      - Changed from deprecated `registerCoreModule` to `setExtensionUnloadMode`
      - Simplified and improved a lot of the code
      - Added a `defaults` table for variables
]]

-- Utility Functions
------------------------------------------------------------
local function findObject(objectName, className)
    local obj = scenetree.findObject(objectName)
    if obj then return obj end
    if not className then return nil end

    local objects = scenetree.findClassObjects(className)
    for _, name in pairs(objects) do
        local object = scenetree.findObject(name)
        if string.find(name, objectName) then return object end
    end

    return
end

local function tableToMatrix(tbl)
    local mat = MatrixF(true)
    mat:setColumn(0, tbl.c0)
    mat:setColumn(1, tbl.c1)
    mat:setColumn(2, tbl.c2)
    mat:setColumn(3, tbl.c3)
    return mat
end

local function tooltip(text)
    imgui.TextDisabled("(?)")
    if not imgui.IsItemHovered() then return end

    imgui.BeginTooltip()
    imgui.PushTextWrapPos(imgui.GetFontSize() * 35.0);
    imgui.TextUnformatted(text)
    imgui.EndTooltip()
end

local function slider(name, ptr, min, max, format, default, v)
    imgui.SliderFloat(name, ptr, min, max, format)

    if imgui.BeginPopupContextItem("##popup" .. name) then
        if imgui.MenuItem1("Reset") then
            if not cb then ptr[0] = default else cb() end
        end
        
        imgui.EndPopup()
    end

    return ptr[0]
end

-- Rain Functions
------------------------------------------------------------
local function getRainAmount()
    local rain = findObject("rain_coverage","Precipitation")
    if rain then
        local drops = rain.numDrops
        return drops / 255 * M.presetData.rainMultiplier
    end

    return 0
end

local function setRainVolume(vol)
    local soundObj = findObject("rain_sound")
    if soundObj then
        soundObj:delete()
    end

    soundObj = createObject("SFXEmitter")
    soundObj.scale = Point3F(100, 100, 100)
    soundObj.fileName = String('/art/sound/environment/amb_rain_medium.ogg')
    soundObj.playOnAdd = true
    soundObj.isLooping = true
    soundObj.volume = vol
    soundObj.isStreaming = true
    soundObj.is3D = false
    soundObj:registerObject('rain_sound')
end

local function createRain(numDrops)
    numDrops = numDrops or 0

    local rain = findObject("rain_coverage", "Precipitation")

    if rain then
        rainObj = rain
        rainObj.numDrops = numDrops
        return
    end

    rainObj = createObject("Precipitation")
    rainObj.dataBlock = scenetree.findObject("rain_medium")
    rainObj.numDrops = numDrops
    rainObj.splashSize = 0
    rainObj.splashMS = 0
    rainObj.animateSplashes = 0
    rainObj.boxWidth = 16.0
    rainObj.boxoceanHeight = 10.0
    rainObj.dropSize = 1.0
    rainObj.doCollision = true
    rainObj.hitVehicles = true
    rainObj.rotateWithCamVel = true
    rainObj.followCam = true
    rainObj.useWind = true
    rainObj.minSpeed = 0.4
    rainObj.maxSpeed = 0.5
    rainObj.minMass = 4
    rainObj.masMass = 5
    rainObj:registerObject('rain_coverage')
end

local function resetRain(delete)
    delete = delete or false

    local rain = findObject("rain_coverage","Precipitation")
    local sound = findObject("rain_sound")

    if delete then
        if imgui.GetWindowHeight() == windowMinHeight then
            shouldResetWindowHeight = true
        end

        windowMinHeight = defaultWindowHeight
    end

    if rain then
        rain.numDrops = 0
        if delete then rainObj:delete() end

        rainObj = rain
    end

    if sound then
        setRainVolume(0)
        if delete then sound:delete() end
    end
end

-- Water/Ocean Functions
------------------------------------------------------------
local function getOcean()
    local waterPlane = findObject("Ocean", "WaterPlane")
    if waterPlane then
        initialWaterPosition = waterPlane.position
    end

    return waterPlane
end

local function resetWaterLevel()
    if not M.ocean then return end
    M.ocean.position = initialWaterPosition
    ptrWaterLevel[0] = initialWaterPosition:getColumn(3).z
end

local function resetAllWaterSources()
    for id, water in pairs(waterSources) do
        water.isRenderEnabled = true
        hiddenWater[id] = false
    end
end

local function reset()
    resetWaterLevel()
    resetAllWaterSources()
end

local function getWaterLevel()
    if not M.ocean then return end
    return M.ocean.position:getColumn(3).z
end

local function setWaterLevel(level)
    if not M.ocean then log("W", "setWaterLevel", "M.ocean is nil") return end
    local c3 = M.ocean.position:getColumn(3)
    M.ocean.position = tableToMatrix({
        c0 = M.ocean.position:getColumn(0),
        c1 = M.ocean.position:getColumn(1),
        c2 = M.ocean.position:getColumn(2),
        c3 = vec3(c3.x, c3.y, level)
    })
end

local function getAllWater()
    local water = {}
    local toSearch = {
        "River",
        "WaterBlock"
    }

    for _, name in pairs(toSearch) do
        local objects = scenetree.findClassObjects(name)
        for _, id in pairs(objects) do
            if not tonumber(id) then
                local source = scenetree.findObject(id)
                if source then
                    table.insert(water, source)
                end
            else
                local source = scenetree.findObjectById(tonumber(id))
                if source then
                    table.insert(water, source)
                end
            end
        end
    end

    return water
end

local function hideCoveredWater()
    local oceanHeight = ptrWaterLevel[0]

    for id, water in pairs(waterSources) do
        local wateroceanHeight = water.position:getColumn(3).z
        if M.presetData.hideCoveredWater and not hiddenWater[id] and wateroceanHeight < oceanHeight then
            water.isRenderEnabled = false
            hiddenWater[id] = true
        elseif wateroceanHeight > oceanHeight and hiddenWater[id] then
            water.isRenderEnabled = true
            hiddenWater[id] = false
        elseif not M.presetData.hideCoveredWater and hiddenWater[id] then
            water.isRenderEnabled = true
            hiddenWater[id] = false
        end
    end
end

local function setup()
    if imgui.GetWindowHeight() == windowMinHeight then -- If we have manually changed the window size, don't set it
        shouldResetWindowHeight = true
    end

    windowMinHeight = defaultWindowHeight
    initialWaterPosition = nil

    M.ocean = nil
    rainObj = nil
    waterSources = {}
    hiddenWater = {}
end

local windowWidth = 0

local function renderUI()
    floodui.pushStyle(imgui.StyleVar_WindowMinSize,     imgui.ImVec2(330.0, windowMinHeight))
    floodui.pushStyle(imgui.StyleVar_WindowTitleAlign,  imgui.ImVec2(0.5, 0.5))
    floodui.pushStyle(imgui.StyleVar_WindowPadding,     imgui.ImVec2(4.0, 4.0))
    floodui.pushStyle(imgui.StyleVar_ItemSpacing,       imgui.ImVec2(6.0, 4.0))
    floodui.pushStyle(imgui.StyleVar_WindowBorderSize,  0.0)
    floodui.pushStyle(imgui.StyleVar_WindowRounding,    0.0)

    floodui.pushColor(imgui.Col_WindowBg,               imgui.ImVec4(0.18, 0.2, 0.24, 1.0))

    floodui.pushColor(imgui.Col_TitleBg,                imgui.ImVec4(0.18, 0.2, 0.24, 1.0))
    floodui.pushColor(imgui.Col_TitleBgActive,          imgui.ImVec4(0.18, 0.2, 0.24, 1.0))
    floodui.pushColor(imgui.Col_TitleBgCollapsed,       imgui.ImVec4(0.18, 0.2, 0.24, 1.0))

    floodui.pushColor(imgui.Col_MenuBarBg,              imgui.ImVec4(0.18, 0.2, 0.24, 1.0))
    floodui.pushColor(imgui.Col_PopupBg,                imgui.ImVec4(0.18, 0.2, 0.24, 1.0))

    floodui.pushColor(imgui.Col_Separator,              imgui.ImVec4(0.85, 0.75, 0.55, 1.0))
    floodui.pushColor(imgui.Col_SeparatorHovered,       imgui.ImVec4(0.85, 0.75, 0.55, 1.0))
    floodui.pushColor(imgui.Col_SeparatorActive,        imgui.ImVec4(0.85, 0.75, 0.55, 1.0))

    floodui.pushColor(imgui.Col_CheckMark,              imgui.ImVec4(0.85, 0.75, 0.55, 1.0))

    floodui.pushColor(imgui.Col_Button,                 imgui.ImVec4(0.37, 0.46, 0.56, 1.0))
    floodui.pushColor(imgui.Col_ButtonHovered,          imgui.ImVec4(0.71, 0.56, 0.58, 1.0))
    floodui.pushColor(imgui.Col_ButtonActive,           imgui.ImVec4(0.27, 0.36, 0.46, 1.0))

    floodui.pushColor(imgui.Col_FrameBg,                imgui.ImVec4(0.37, 0.46, 0.56, 1.0))
    floodui.pushColor(imgui.Col_FrameBgHovered,         imgui.ImVec4(0.71, 0.56, 0.58, 1.0))
    floodui.pushColor(imgui.Col_FrameBgActive,          imgui.ImVec4(0.27, 0.36, 0.46, 1.0))

    floodui.pushColor(imgui.Col_SliderGrab,             imgui.ImVec4(0.27, 0.36, 0.46, 1.0))
    floodui.pushColor(imgui.Col_SliderGrabActive,       imgui.ImVec4(0.85, 0.75, 0.55, 1.0))

    floodui.pushColor(imgui.Col_TextSelectedBg,         imgui.ImVec4(0.71, 0.56, 0.58, 1.0))

    windowMinHeight = M.presetData.rainEnabled and expandedWindowHeight or defaultWindowHeight

    -- This gets set when "Rain Enabled" is disabled. If you don't manually resize, it will update to fit all the contents. Otherwise, it will keep the size you set
    if shouldResetWindowHeight then
        imgui.SetNextWindowSize(imgui.ImVec2(windowWidth, defaultWindowHeight), imgui.Cond_Always)
        shouldResetWindowHeight = false
    end

    -- Main window, this is where all the options are
    if imgui.Begin("Flood Controller", M.showUI, imgui.WindowFlags_NoDocking and imgui.WindowFlags_MenuBar) then
        local windowHeight = imgui.GetWindowHeight()

        -- Menu Bar
        if imgui.BeginMenuBar() then
            if imgui.BeginMenu("Help") then
                imgui.Text("Release Notes")
                if imgui.IsItemHovered() then
                    imgui.SetTooltip(changes)
                end

                imgui.Text("Editing Values")
                if imgui.IsItemHovered() then
                    imgui.SetTooltip("You can press (CTRL + Left Mouse) to manually edit each value in the sliders, \nit's helpful if you need it to be precise (or if you want to override the max value)")
                end

                if not M.ocean then
                    imgui.Text("Ocean")
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip("This level does not have an ocean, UI elements have been disabled")
                    end
                end

                imgui.Text("Version: " .. version)
                imgui.EndMenu()
            end

            if not M.ocean then imgui.BeginDisabled() end

            if imgui.BeginMenu("Presets") then
                imgui.PushItemWidth(128)

                local saving = false
                if imgui.InputText("##save_new_preset", presetNameBuffer, nil, imgui.InputTextFlags_EnterReturnsTrue) then
                    imgui.SetKeyboardFocusHere(-1)
                    saving = true
                end
                imgui.PopItemWidth()

                local newPresetName = ffi.string(presetNameBuffer)

                if newPresetName == defaultPresetName then imgui.BeginDisabled() end

                imgui.SameLine()
                if imgui.Button("Save") then
                    saving = true
                end

                if newPresetName == defaultPresetName then imgui.EndDisabled() end

                if saving then
                    if #newPresetName > 0 then
                        -- If we overwrite our save, we don't want to stop the flood if we have started it
                        local enableFlood = false
                        if newPresetName == activePreset and M.presetData.enabled then
                            enableFlood = true
                        end

                        if not presetManager.savePreset(newPresetName, M.presetData) then
                            print("Preset already exists")
                        end

                        local preset = presetManager.getPreset(newPresetName)
                        if preset then
                            M.presetData = shallowcopy(preset.data)
                            activePreset = preset.name

                            if enableFlood then M.presetData.enabled = true end
                        end

                        ffi.copy(presetNameBuffer, activePreset)
                    end
                end

                local shouldUpdateRainAndWindow = false

                for _, preset in ipairs(presetManager.getPresets()) do
                    local isActive = preset.name == activePreset
                    if isActive then imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0.71, 0.56, 0.58, 1.0)) end

                    imgui.Button(preset.name, imgui.ImVec2(128, 0))
                    if isActive then imgui.PopStyleColor() end

                    imgui.SameLine()

                    -- Load
                    if imgui.Button("L##" .. preset.name) then
                        local preset = presetManager.getPreset(preset.name)
                        if not preset then
                            log('E', 'presetManager', 'Failed loading preset: ' .. preset.name)
                            goto continue
                        end

                        M.presetData = shallowcopy(preset.data)
                        activePreset = preset.name

                        ffi.copy(presetNameBuffer, activePreset)
                        shouldUpdateRainAndWindow = true

                        log('I', 'presetManager', 'Loaded preset: ' .. preset.name)
                        ::continue::
                    end

                    if imgui.IsItemHovered() then
                        imgui.SetTooltip("Load Preset")
                    end

                    -- Reset
                    if not isActive then imgui.BeginDisabled() end
                    imgui.SameLine()
                    if imgui.Button("R##" .. preset.name) then
                        M.presetData = shallowcopy(presetManager.defaults)

                        if not M.presetData.rainEnabled then
                            if windowHeight == expandedWindowHeight then
                                windowMinHeight = defaultWindowHeight
                                shouldResetWindowHeight = true
                            end

                            resetRain()
                        else
                            createRain(M.presetData.rainAmount)
                            setRainVolume(M.presetData.rainVolume)
                        end
                    end
                    if not isActive then imgui.EndDisabled() end
                    if imgui.IsItemHovered() then imgui.SetTooltip("Reset Preset (Will not save)") end

                    -- Delete
                    if preset.name == defaultPresetName then imgui.BeginDisabled() end

                    imgui.SameLine()
                    imgui.PushStyleColor2(imgui.Col_ButtonHovered, imgui.ImVec4(0.94, 0.35, 0.35, 1.0))
                    if imgui.Button("D##" .. preset.name) then
                        if preset.name == activePreset then
                            local defaultPreset = presetManager.getPreset(defaultPresetName)
                            if not defaultPreset then
                                log('D', 'Delete Preset', 'Could not load default preset after deleting ' .. preset.name)
                                activePreset = ""
                            else
                                M.presetData = shallowcopy(defaultPreset.data)
                                activePreset = defaultPresetName

                                shouldUpdateRainAndWindow = true
                            end

                            ffi.copy(presetNameBuffer, activePreset)
                        end

                        presetManager.deletePreset(preset.name)
                        log('I', 'presetManager', 'Deleted preset: ' .. preset.name)
                    end
                    imgui.PopStyleColor()

                    if preset.name == defaultPresetName then imgui.EndDisabled() end
                    if imgui.IsItemHovered() then imgui.SetTooltip("Delete Preset") end
                end

                if shouldUpdateRainAndWindow then
                    if not M.presetData.rainEnabled then
                        if windowHeight == expandedWindowHeight then
                            windowMinHeight = defaultWindowHeight
                            shouldResetWindowHeight = true
                        end

                        resetRain()
                    else
                        createRain(M.presetData.rainAmount)
                        setRainVolume(M.presetData.rainVolume)
                    end
                end

                imgui.EndMenu()
            end

            imgui.EndMenuBar()
        end

        imgui.Separator()

        windowWidth = imgui.GetWindowWidth()

        local ptrGradualReturn = imgui.BoolPtr(M.presetData.gradualReturn)
        local ptrDecrease = imgui.BoolPtr(M.presetData.decrease)
        local ptrLimitEnabled = imgui.BoolPtr(M.presetData.limitEnabled)
        local ptrFloodWithRain = imgui.BoolPtr(M.presetData.floodWithRain)
        local ptrHideCoveredWater = imgui.BoolPtr(M.presetData.hideCoveredWater)
        local ptrStopWhenSubmerged = imgui.BoolPtr(M.presetData.stopWhenSubmerged)
        local ptrRainMultiplier = imgui.FloatPtr(M.presetData.rainMultiplier)
        local ptrSpeed = imgui.FloatPtr(M.presetData.speed)
        local ptrLimit = imgui.FloatPtr(M.presetData.heightLimit)
        local ptrRainAmount = imgui.FloatPtr(M.presetData.rainAmount)
        local ptrRainVolume = imgui.FloatPtr(M.presetData.rainVolume)
        local ptrRainEnabled = imgui.BoolPtr(M.presetData.rainEnabled)

        if imgui.Checkbox("Gradual Return", ptrGradualReturn) then
            M.presetData.gradualReturn = ptrGradualReturn[0]
            M.presetData.decrease = false 
        end
        imgui.SameLine()
        tooltip("This option will gradually raise/lower the water level to its starting position.\nWhen it's close to it, it will just set itself to the starting level so it's 100% correct")

        if imgui.Checkbox("Decrease", ptrDecrease) then
            M.presetData.decrease = ptrDecrease[0]
            M.presetData.gradualReturn = false
        end

        if imgui.Checkbox("Limit", ptrLimitEnabled) then
            M.presetData.limitEnabled = ptrLimitEnabled[0]
        end

        if imgui.Checkbox("Hide overlapped water sources", ptrHideCoveredWater) then
            M.presetData.hideCoveredWater = ptrHideCoveredWater[0]
            hideCoveredWater()
        end
        imgui.SameLine()
        tooltip("This option will hide water sources that are below the ocean, this prevents weird visuals when going under water.")

        if imgui.Checkbox("Stop when submerged", ptrStopWhenSubmerged) then
            M.presetData.stopWhenSubmerged = ptrStopWhenSubmerged[0]
        end

        if imgui.Checkbox("Rain Enabled", ptrRainEnabled) then
            if not rainObj then createRain() end

            M.presetData.rainEnabled = ptrRainEnabled[0]

            if imgui.GetWindowHeight() == windowMinHeight then -- If we have manually changed the window size, don't set it
                shouldResetWindowHeight = true
            end

            if not M.presetData.rainEnabled then
                windowMinHeight = defaultWindowHeight
                if rainObj then
                    rainObj.numDrops = 0
                end
            else
                windowMinHeight = expandedWindowHeight
                setRainVolume(M.presetData.rainVolume)
            end
        end

        if imgui.Checkbox("Flood with rain", ptrFloodWithRain) then
            M.presetData.floodWithRain = ptrFloodWithRain[0]
        end

        imgui.SameLine()
        tooltip("When enabled, the water will slowly rise depending on the rain amount and the multiplier\nIf you only want rain to affect the water level, set `Speed` to 0 (the first slider)")

        -- Main Buttons
        ------------------------------------------------------------
        imgui.Separator()
        if imgui.Button(M.presetData.enabled and "Stop" or "Start") then
            M.presetData.enabled = not M.presetData.enabled
        end

        imgui.SameLine()

        if imgui.Button("Reset Water Level") then
            M.presetData.enabled = false
            M.presetData.gradualReturn = false

            reset()
        end

        imgui.Separator()

        M.presetData.speed          = slider("Speed", ptrSpeed, 0, M.maxSpeed, "%.6f", presetManager.defaults.speed)
        M.presetData.rainMultiplier = slider("Rain Multiplier", ptrRainMultiplier, 0, 0.5, "%.6f", presetManager.defaults.rainMultiplier)
        M.presetData.heightLimit    = slider("Height Limit", ptrLimit, -500, 500, "%.6f", presetManager.defaults.heightLimit)

        -- Water Level
        if imgui.SliderFloat("Water Level", ptrWaterLevel, -500, 500, "%.6f") then
            setWaterLevel(ptrWaterLevel[0])
        end

        if imgui.BeginPopupContextItem("##popup_water_level") then
            if imgui.MenuItem1("Reset") then
                resetWaterLevel()
            end
            
            imgui.EndPopup()
        end

        -- Environmental Options
        ------------------------------------------------------------
        imgui.Separator()

        local strHours = ""
        local strMinutes = ""

        if displayHours < 10 then strHours = "0" .. tostring(displayHours) else strHours = tostring(displayHours) end
        if ptrMinutes[0] < 10 then strMinutes = "0" .. tostring(ptrMinutes[0]) else strMinutes = tostring(ptrMinutes[0]) end

        floodui.textCenter("Environment | Time: " .. strHours .. ":" .. strMinutes)

        -- Time of day
        local tod = core_environment.getTimeOfDay()
        local time = tod.time
        local seconds = ((time + 0.5) % 1) * 86400
        local hours = math.floor(seconds / 3600)
        local minutes = math.floor(seconds / 60 - (hours * 60))

        displayHours = hours
        ptrMinutes[0] = minutes

        if time <= 0.5 then
            ptrHoursMilitary[0] = math.floor(displayHours - 12)
        else
            ptrHoursMilitary[0] = math.floor(12 + displayHours)
        end

        local updateTime = false
        if imgui.SliderFloat("Hours", ptrHoursMilitary, 0, 24, strHours) then
            ptrHoursMilitary[0] = math.floor(ptrHoursMilitary[0])
            if ptrHoursMilitary[0] == 24 then ptrMinutes[0] = 0 end

            updateTime = true
        end

        if imgui.SliderInt("Minutes", ptrMinutes, 0, 59, strMinutes) then
            updateTime = true

            -- Nice little loopback :)
            if ptrHoursMilitary[0] == 24 and ptrMinutes[0] > 0 then
                ptrHoursMilitary[0] = 0
            end
        end

        if updateTime then
            local magicValue = 0.01

            local totalSeconds = (ptrHoursMilitary[0] * 3600) + ((ptrMinutes[0] + magicValue) * 60) -- The magicValue fixes the minute changing when changing hour, it was just a random guess, but it works..
            local res = math.min(1, totalSeconds / 86400) -- magicValue slightly goes over 1 if the hour is 12, so just heightLimit it.

            core_environment.setTimeOfDay({time = res})
        end

        -- Rain
        if M.presetData.rainEnabled then
            createRain(M.presetData.rainAmount)

            if rainObj then
                if imgui.SliderFloat("Rain Amount", ptrRainAmount, 0, 1000, "%.2f") then
                    M.presetData.rainAmount = ptrRainAmount[0]
                    rainObj.numDrops = ptrRainAmount[0]
                end

                if imgui.SliderFloat("Rain Volume", ptrRainVolume, 0, 1, "%.2f") then
                    M.presetData.rainVolume = ptrRainVolume[0]
                    setRainVolume(M.presetData.rainVolume)
                end
                imgui.SameLine()
                tooltip("Sliding this will lag because I have to destroy and create a new sound source. Setting volume realtime doesn't work.")
            end
        end

        if not M.ocean then
            imgui.EndDisabled()
        end

        imgui.End()
end

    floodui.popAll()
end

-- Game Callbacks
------------------------------------------------------------
local function onUpdate(dt)
    if not inMission then return end

    if activePreset == "" then return end -- Not good!
    if M.showUI[0] then renderUI() end

    if not M.presetData.enabled or not M.ocean then return end
    hideCoveredWater()

    if bullettime.getPause() then return end

    local oceanHeight = getWaterLevel()
    dt = dt * bullettime.get() -- Sync with bullettime. I would use dtsim, but I don't want to ruin the timings on the flood map

    if M.presetData.floodWithRain then
        local amount = getRainAmount() * M.presetData.rainMultiplier
        local newOceanHeight = oceanHeight + amount * bullettime.get()
        oceanHeight = M.presetData.limitEnabled and math.min(newOceanHeight, M.presetData.heightLimit) or newOceanHeight
    end

    if M.presetData.gradualReturn then
        local initialZ = initialWaterPosition:getColumn(3).z
        local curZ = ptrWaterLevel[0]
        local precision = 0.05 -- I wouldn't recommend lowering this, even though this can still have slight issues (when speed is 50)
    
        if math.abs(initialZ - curZ) > precision then
            local newZ = curZ + (initialZ < curZ and -1 or 1) * M.presetData.speed * dt
            ptrWaterLevel[0] = newZ
            setWaterLevel(newZ)
        else
            M.presetData.gradualReturn = false
            M.presetData.enabled = false

            resetWaterLevel() -- We call this because it will make sure it's the exact value it was on map load.
        end
    else
        -- Increase/Decrease the water level
        local target = oceanHeight + (M.presetData.decrease and -1 or 1) * M.presetData.speed * dt
    
        if M.presetData.limitEnabled then
            oceanHeight = M.presetData.decrease and math.max(target, M.presetData.heightLimit) or math.min(target, M.presetData.heightLimit)
            if oceanHeight == M.presetData.heightLimit then
                M.presetData.limitEnabled = false
                M.presetData.enabled = false
            end
        else
            oceanHeight = target
        end
    
        ptrWaterLevel[0] = oceanHeight
        setWaterLevel(oceanHeight)
    end

    if M.presetData.stopWhenSubmerged then
        local veh = be:getPlayerVehicle(0)
        if not veh then return end

        local boundingBox = veh:getSpawnWorldOOBB()
        local halfExtentsZ = boundingBox:getHalfExtents().z
        local height = halfExtentsZ * 2
        local pos = veh:getPosition()
        if oceanHeight >= pos.z + height then
            M.presetData.enabled = false
        end
    end
end

local function onExtensionUnloaded()
    resetRain()
    reset()
    setup()
end

local function onClientStartMission()
    local mission = getMissionFilename()
    if mission == "" then inMission = false return end

    setup()

    for _, water in pairs(waterSources) do
        water.isRenderEnabled = true
    end

    M.presetData = shallowcopy(presetManager.defaults)
    activePreset = defaultPresetName

    ffi.copy(presetNameBuffer, defaultPresetName)

    waterSources = getAllWater()
    M.ocean = getOcean()

    setRainVolume(0)
    ptrWaterLevel[0] = getWaterLevel() or 0

    inMission = true

    if not mission then return end
end

local function onExtensionLoaded()
    onClientStartMission() -- Just because it sets stuff up for us

    if not presetManager.loadPresets() then
        presetManager.savePreset(defaultPresetName, presetManager.defaults)
    end

    M.presetData = shallowcopy(presetManager.defaults)
    activePreset = defaultPresetName

    ffi.copy(presetNameBuffer, defaultPresetName)
end

local function onClientEndMission()
    inMission = false
    setup()
end

-- Public Interface
------------------------------------------------------------
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate

M.resetWaterLevel = resetWaterLevel
M.resetAllWaterSources = resetAllWaterSources
M.reset = reset
M.getWaterLevel = getWaterLevel
M.setWaterLevel = setWaterLevel
M.reload = reload

return M