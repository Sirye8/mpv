-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(make_sheet, send, options, review_entry)
    local popup, offer, prompt, deadline, busy, notice
    local timer, transition, keep_open, keep_open_pause
    local bindings={}
    local statuses={CURRENT="Watching",PLANNING="Planning",PAUSED="Paused",
        DROPPED="Dropped",COMPLETED="Completed",REPEATING="Rewatching"}

    local function release_end(command)
        local commands={}
        if keep_open then
            if mp.get_property("keep-open")=="always" then
                commands[#commands+1]="set file-local-options/keep-open "..keep_open
            end
        end
        if keep_open_pause and mp.get_property("keep-open-pause")=="no" then
            commands[#commands+1]="set file-local-options/keep-open-pause "..keep_open_pause
        end
        keep_open,keep_open_pause=nil,nil
        if command then commands[#commands+1]=command end
        if #commands>0 then mp.command(table.concat(commands,"; ")) end
    end

    local function clear_bindings()
        for _,id in ipairs(bindings) do mp.remove_key_binding(id) end
        bindings={}
    end

    local function set_timeout(seconds)
        if timer then timer:kill(); timer=nil end
        deadline=nil
        if seconds>0 then
            deadline=mp.get_time()+seconds
            timer=mp.add_timeout(seconds,function() popup.close() end)
        end
    end

    local function submit(op, keep)
        if busy or not prompt then return end
        busy=true
        notice=nil
        set_timeout(25)
        local proposal=prompt.proposal
        send({action="service",session=prompt.session,ask_prompt=prompt.id,
            job={op=op,account=proposal.account,proposal=proposal.key,keep_status=keep,
                notice_page="AniList update"}})
        popup.draw()
    end

    popup=make_sheet({
        compact=true,sections={},scale=options.menu_scale,animate=options.menu_animations,
        position=function() return prompt and prompt.position or "top-right" end,
        refresh=function() popup.draw() end,
        footer=function()
            if busy then return "Later · Saving…" end
            local action=prompt and prompt.proposal.review_only and "Continue" or "Later"
            return deadline and action.." · "..math.max(0,math.ceil(deadline-mp.get_time())).." s" or action
        end,
        closed=function()
            local previous,command=prompt,transition
            prompt,notice,busy=nil,nil,false
            offer,transition=nil,nil
            set_timeout(0)
            clear_bindings()
            if popup.terminal then mp.set_property("term-status-msg",popup.old_term or "") end
            if previous then send({action="ask_dismiss",session=previous.session,id=previous.id}) end
            release_end(command)
        end,
        rows=function()
            local p=prompt.proposal
            local base=p.base or {}
            local rows={}
            local function row(id,label,tip,action,primary)
                rows[#rows+1]={id=id,label=label,tip=tip,run=action,disabled=not action,primary=primary}
            end
            if p.review_only then
                row("episode",p.title or "Anime","The AniList entry currently matched to this file.")
                row("reason",p.review_only,"This file has no confirmed whole episode to send to AniList. Continue to leave without updating, or open the AniList entry to review its progress.")
                if review_entry then
                    row("review","View AniList entry","Open the matched entry in your browser. The current mpv action waits for Continue.",function()
                        review_entry(p.media)
                    end)
                end
                return rows
            end
            local progress=tostring(p.before).." → "..p.episode
            row("episode",(p.title and p.title~="" and p.title or "Anime").."   Episode "..p.episode,
                "The AniList entry and episode selected by recognition.")
            row("progress","Progress   "..progress..(p.episode>p.before+1 and " · Episode gap" or ""),
                "Review the absolute progress value before updating AniList.")
            if p.status then
                local status=(statuses[base.status] or "New entry").." → "..statuses[p.status]
                if p.repeat_count then status=status.." · Rewatches "..(base["repeat"] or 0).." → "..p.repeat_count end
                row("status","Status   "..status,"The list status and rewatch count that this update would set.")
            end
            if notice then row("notice",notice,"Result of the last update attempt.") end
            if not busy then
                local action="Update AniList"
                if p.repeat_count then action=p.start_rewatch and "Record completed rewatch" or "Finish rewatch"
                elseif p.start_rewatch then action="Start rewatch and record episode 1"
                elseif p.status=="REPEATING" then action="Resume rewatch and update"
                elseif p.status=="CURRENT" then action=base.id and "Switch to Watching and update" or "Add to Watching and update" end
                row("update",action,"Apply the episode progress and any status change shown above.",function() submit("accept",false) end,true)
                if p.status=="CURRENT" and base.id then
                    row("keep","Update progress only","Keep this status for this entry's later updates.",function() submit("accept",true) end)
                end
                row("skip","Skip this episode","Dismiss this update for the current viewing cycle.",function() submit("skip") end)
            end
            return rows
        end,
    })

    local function show(command)
        if prompt then return true end
        local w,h=mp.get_osd_size()
        if not (w and w>0 and h>0) and not mp.get_property_bool("terminal",true) then return false end
        prompt,busy,notice=offer,false,nil
        set_timeout(prompt.seconds)
        local ok,err=pcall(popup.show,prompt.proposal.review_only and "Review AniList match" or "AniList update")
        if not ok then
            mp.msg.warn("Could not show AniList review: "..tostring(err))
            if popup.open then popup.close() else prompt=nil; set_timeout(0) end
            return false
        end
        transition=command
        return true
    end

    local leave_commands={quit=true,["quit-watch-later"]=true,["playlist-next"]=true,["playlist-prev"]=true}
    local function is_leave_command(cmd)
        if type(cmd)~="string" then return false end
        local name,args=cmd:match("^%s*([%w-]+)%s*(.-)%s*$")
        if name=="script-binding" then return args=="uosc/next" or args=="uosc/prev" end
        return leave_commands[name] and (args=="" or args=="weak" or args=="force" or args:match("^%-?%d+$"))
    end

    local function leave(command)
        if prompt and prompt.timing~="threshold" then
            -- If review already started at EOF, honor the first requested action.
            transition=transition or command
        elseif not (offer and offer.timing=="leave" and show(command)) then
            mp.command(command)
        end
    end

    local function bind_leave_keys()
        local active={}
        for _,binding in ipairs(mp.get_property_native("input-bindings",{})) do
            local previous=active[binding.key]
            if binding.priority>=0 and (not previous or previous.priority<binding.priority) then
                active[binding.key]=binding
            end
        end
        for key,binding in pairs(active) do
            if binding.section=="default" and is_leave_command(binding.cmd) then
                local id="rich_presence_review_"..key
                mp.add_forced_key_binding(key,id,function() leave(binding.cmd) end)
                bindings[#bindings+1]=id
            end
        end
    end

    local function reached_end(_,eof)
        if eof and offer and offer.timing~="threshold" and not show() then
            offer=nil
            clear_bindings()
            release_end()
        end
    end

    local function arm_end()
        local original=mp.get_property("keep-open","no")
        if original~="always" and mp.set_property("file-local-options/keep-open","always") then
            keep_open=original
        end
        if not keep_open_pause then keep_open_pause=mp.get_property("keep-open-pause","yes") end
        mp.set_property("file-local-options/keep-open-pause","no")
        reached_end(nil,mp.get_property_bool("eof-reached",false))
    end

    local function reset()
        transition=nil
        -- mpv has already restored the file-local options.
        keep_open,keep_open_pause=nil,nil
        if prompt then popup.close() end
        offer=nil
        clear_bindings()
    end

    return {
        offer=function(value)
            if prompt and prompt.id==value.id then return end
            if prompt then popup.close() end
            if not offer or offer.id~=value.id or offer.timing~=value.timing then
                clear_bindings()
                release_end()
                if not value.id then offer=nil; return end
                offer=value
                if value.timing=="threshold" then
                    if not show() then
                        offer=nil
                        send({action="ask_dismiss",session=value.session,id=value.id})
                    end
                else
                    -- Keep the last frame in the normal playback loop. mpv
                    -- stops drawing overlays once on_unload starts.
                    if value.timing=="leave" then bind_leave_keys() end
                    arm_end()
                end
            else offer=value end
        end,
        end_changed=reached_end,
        reset=reset,
        playback_restart=function()
            if offer and offer.timing~="threshold" then arm_end() end
            send({action="ask_refresh"})
        end,
        leave=function(command)
            if is_leave_command(command) then leave(command) end
        end,
        notice=function(message)
            if not prompt then return end
            busy=false
            set_timeout(prompt.seconds)
            notice=message
            popup.draw()
        end,
    }
end
