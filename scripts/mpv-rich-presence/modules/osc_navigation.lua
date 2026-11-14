-- SPDX-License-Identifier: AGPL-3.0-or-later
local function forward(command)
    return 'script-message-to mpv_rich_presence review-before "'..command..'"'
end

return function(read_options)
    -- Both OSC scripts watch script-opts and rebuild their controls. Keep the
    -- wrapper in memory so their config files and custom bindings stay intact.
    local script_opts=mp.get_property_native("options/script-opts",{})
    for _,direction in ipairs({"prev","next"}) do
        local key="playlist_"..direction.."_mbtn_left_command"
        local command="playlist-"..direction
        local osc_options={[key]=command}
        read_options(osc_options,"osc")
        if osc_options[key]==command or osc_options[key]==command.." weak" or osc_options[key]==command.." force" then
            script_opts["osc-"..key]=forward(osc_options[key])
        end
    end

    local uosc=mp.find_config_file("scripts/uosc/main.lua")
    if uosc then
        local file=io.open(uosc,"r")
        local defaults=file and file:read("*a")
        if file then file:close() end
        local controls=defaults and defaults:match("controls%s*=%s*['\"]([^'\"]+)")
        if controls then
            local options={controls=controls}
            read_options(options,"uosc")
            local original=options.controls
            local items,start,disposition={},1,false
            for i=1,#original+1 do
                local ch=original:sub(i,i)
                if i==start and ch=="<" then disposition=true end
                if ch==">" then disposition=false end
                if (ch=="," and not disposition) or i>#original then
                    local item=original:sub(start,i-1)
                    local prefix,control=item:match("^(<[^>]+>)(.+)$")
                    control=(control or item):match("^%s*(.-)%s*$")
                    if control=="prev" or control=="next" then
                        local previous=control=="prev"
                        item=(prefix or "").."command:arrow_"..(previous and "back" or "forward")..
                            "_ios:"..forward("script-binding uosc/"..control).."?"..(previous and "Previous" or "Next")
                    end
                    items[#items+1]=item
                    start=i+1
                end
            end
            local updated=table.concat(items,",")
            if updated~=original then script_opts["uosc-controls"]=updated end
        end
    end
    mp.set_property_native("options/script-opts",script_opts)
end
