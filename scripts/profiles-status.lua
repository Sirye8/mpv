-- Variable to track if any profile is active
local last_active_profiles = {}

-- Function to update and show active profiles
function show_active_profiles()
    -- Fetch the current values of the statuses
    local simulcast_status = mp.get_property_native("user-data/simulcast-status")
    local enhance_status = mp.get_property_native("user-data/enhance-status")
    local downmix_status = mp.get_property_native("user-data/downmix-status")

    -- Initialize the text
    local profiles = {}

    -- Add each status to the profiles list if it exists
    if simulcast_status=="Simulcast" then
        table.insert(profiles, simulcast_status)
    end
    if enhance_status=="Enhance" then
        table.insert(profiles, enhance_status)
    end
    if downmix_status=="Downmix" then
        table.insert(profiles, downmix_status)
    end

   -- If no profiles are active, show "None" if it was the last profile
    if #profiles == 0 then
        if next(last_active_profiles) then
            mp.commandv("show-text", "Active Profiles: None", 1000)
        end
        last_active_profiles = {}
        return
    end

    -- Update the last_active_profiles table if any profile is active
    last_active_profiles = profiles

    -- Combine the profiles into a single string
    local text = "Active Profiles: " .. table.concat(profiles, ", ")

    -- Show the text on screen for 5 seconds
    mp.commandv("show-text", text, 1000)
end


-- Observe the relevant properties and call show_active_profiles when they change
mp.observe_property("user-data/simulcast-status", "string", show_active_profiles)
mp.observe_property("user-data/enhance-status", "string", show_active_profiles)
mp.observe_property("user-data/downmix-status", "string", show_active_profiles)

mp.add_key_binding("?", "show-active-profiles", show_active_profiles)
mp.add_key_binding("?", "show-active-profiles", function()
    -- If no profiles are active, show "None"
    if #last_active_profiles == 0 then
        mp.commandv("show-text", "Active Profiles: None", 1000)
    else
        -- Otherwise, call the original function
        show_active_profiles()
    end
end)