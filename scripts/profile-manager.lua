local msg = require 'mp.msg'

-----------------------------------------------------------
-- STATE & VARIABLES
-----------------------------------------------------------
-- Cycle Profile State
local seperator = ";"
local profileList = mp.get_property_native('profile-list') or {}
local iterator = {}
local profilesDescs = {}

-- Profile Status & Persistence State
local last_states = {}
local update_timer = nil
local is_file_changing = false
local persist_profiles = false
local profile_snapshot = {}

-----------------------------------------------------------
-- HELPER FUNCTIONS (Cycle Profile)
-----------------------------------------------------------
local function mysplit(inputstr, sep)
    if sep == nil then sep = "%s" end
    local t={}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        table.insert(t, str)
    end
    return t
end

local function findDesc(profile)
    msg.verbose('unknown profile ' .. profile .. ', searching for description')
    for i = 1, #profileList do
        if profileList[i] and profileList[i]['name'] == profile then
            local desc = profileList[i]['profile-desc']
            if desc ~= nil then
                profilesDescs[profile] = desc
            else
                profilesDescs[profile] = profile
            end
            return
        end
    end
    profilesDescs[profile] = "no profile '" .. profile .. "'"
end

local function printProfileDesc(profile)
    if profilesDescs[profile] == nil then
        findDesc(profile)
    end
    mp.osd_message(profilesDescs[profile])
end

-----------------------------------------------------------
-- HELPER FUNCTIONS (Profile Status)
-----------------------------------------------------------
function get_cycle_opts()
    local opts = mp.get_property_native("options/script-opts")
    if type(opts) ~= "table" then
        opts = mp.get_property_native("script-opts") or {}
    end
    
    local cycle_states = {}
    for k, v in pairs(opts) do
        if k:sub(1, 6) == "cycle-" then
            cycle_states[k] = v
        end
    end
    return cycle_states
end

function display_status_change(applied, removed)
    local messages = {}
    
    if #applied > 0 then
        table.insert(messages, "Applied Profile: " .. table.concat(applied, ", "))
    end
    
    if #removed > 0 then
        table.insert(messages, "Removed Profile: " .. table.concat(removed, ", "))
    end
    
    if #messages > 0 then
        local final_message = table.concat(messages, " | ")
        -- Show on screen
        mp.osd_message(final_message, 2)
        -- Output to console
        msg.info(final_message)
    end
end

-----------------------------------------------------------
-- CORE LOGIC: PROFILE CYCLING
-----------------------------------------------------------
local function cycle_profiles_main(profileStr)
    local profiles = mysplit(profileStr, seperator)
    local active_index = nil

    -- Fetch the entire script-opts dictionary from mpv as a table
    local opts = mp.get_property_native("options/script-opts") 
    if type(opts) ~= "table" then
        opts = mp.get_property_native("script-opts") or {}
    end

    -- Loop through every profile in this cycle to see if one is currently active
    for index, p in ipairs(profiles) do
        local is_active = false
        
        -- Read the value directly from the table
        local status = opts["cycle-" .. p]
        if status and type(status) == "string" and string.lower(status) == string.lower(p) then
            is_active = true
        end

        if is_active then
            active_index = index
            break
        end
    end

    -- Iterator logic and desync fallback
    if active_index ~= nil then
        iterator[profileStr] = active_index + 1
        if iterator[profileStr] > #profiles then
            iterator[profileStr] = 1
        end
    else
        if iterator[profileStr] == nil then
            iterator[profileStr] = 1
        end
        
        local next_prof = profiles[iterator[profileStr]]
        if next_prof and string.sub(next_prof, -3) == "-no" then
            iterator[profileStr] = 1
        end
    end
    
    local i = iterator[profileStr]

    msg.info("applying profile " .. profiles[i])
    mp.commandv('apply-profile', profiles[i])
    -- printProfileDesc(profiles[i])

    iterator[profileStr] = iterator[profileStr] + 1
    if iterator[profileStr] > #profiles then
        iterator[profileStr] = 1
    end
end

-----------------------------------------------------------
-- CORE LOGIC: PROFILE STATUS & UPDATES
-----------------------------------------------------------
function handle_profile_update()
    local current_states = get_cycle_opts()
    local applied = {}
    local removed = {}

    for k, v in pairs(current_states) do
        local old_val = last_states[k]
        local is_active = (v ~= "null" and v ~= "" and v ~= nil)
        local was_active = (old_val ~= "null" and old_val ~= "" and old_val ~= nil)

        if is_active and (not was_active or v ~= old_val) then
            table.insert(applied, v)
        elseif not is_active and was_active then
            table.insert(removed, old_val)
        end
    end

    last_states = current_states

    -- Only display OSD if changes occurred AND we are not transitioning between files
    if not is_file_changing and (#applied > 0 or #removed > 0) then
        display_status_change(applied, removed)
    end
end

function on_script_opts_change()
    if update_timer then update_timer:kill() end
    update_timer = mp.add_timeout(0.05, handle_profile_update)
end

function show_active_profiles_manual()
    local current_states = get_cycle_opts()
    local active = {}

    for _, v in pairs(current_states) do
        if v ~= "null" and v ~= "" and v ~= nil then
            table.insert(active, v)
        end
    end

    if #active == 0 then
        mp.osd_message("Active Profiles: None", 2)
    else
        mp.osd_message("Active Profiles: " .. table.concat(active, ", "), 2)
    end
end

-----------------------------------------------------------
-- CORE LOGIC: PERSISTENCE & CLEANUP
-----------------------------------------------------------
mp.register_script_message("toggle-profile-persistence", function()
    persist_profiles = not persist_profiles
    mp.set_property_native("user-data/persist_profiles", persist_profiles)
    
    -- Force uosc menu to refresh its checkbox immediately
    local opts = mp.get_property_native("options/script-opts") or {}
    opts["_persist_dummy"] = tostring(os.clock())
    mp.set_property_native("options/script-opts", opts)
    
    mp.osd_message("Profile Persistence: " .. (persist_profiles and "ON" or "OFF"), 2)
end)

mp.register_event("end-file", function(e)
    if e.reason == "quit" or e.reason == "error" then return end
    is_file_changing = true
    
    if update_timer then 
        update_timer:kill() 
        update_timer = nil
    end

    if persist_profiles then
        profile_snapshot = {}
        for k, v in pairs(last_states) do
            profile_snapshot[k] = v
        end

    else
        profile_snapshot = {}
        -- Manually force all active profiles to their "-no" state to bypass 
        -- mpv's failure to natively reset vf-append and script-opts-append
        local current_states = get_cycle_opts()
        for k, v in pairs(current_states) do
            if v ~= "null" and v ~= "" and v ~= nil then
                local base_name = k:sub(7) -- removes "cycle-"
                mp.commandv("apply-profile", base_name .. "-no")
            end
        end
    end
end)

mp.register_event("file-loaded", function()
    -- Reset the cycle iterator on new file load
    iterator = {}

    if persist_profiles and next(profile_snapshot) then
        -- 0.05s delay ensures we overwrite mpv's fresh profile-cond evaluations
        mp.add_timeout(0.05, function()
            for k, v in pairs(profile_snapshot) do
                local base_name = k:sub(7)
                if v ~= "null" and v ~= "" and v ~= nil then
                    mp.commandv("apply-profile", base_name)
                else
                    mp.commandv("apply-profile", base_name .. "-no")
                end
            end
            is_file_changing = false
        end)
    else
        is_file_changing = false
    end
end)

-----------------------------------------------------------
-- INITIALIZATION & BINDINGS
-----------------------------------------------------------
mp.register_script_message('cycle-profiles', cycle_profiles_main)

last_states = get_cycle_opts()
mp.observe_property("script-opts", "native", on_script_opts_change)
mp.add_key_binding("?", "show-active-profiles", show_active_profiles_manual)