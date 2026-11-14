-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(make_sheet, send, options, help)
    local sections={"Now playing","AniList","Appearance","Recognition & folders","Privacy & windows","Saved data","Diagnostics"}
    local sources={
        {"auto","Automatic"},{"anime","Anime"},{"movie-tv","Movies & TV"},{"movie","Movies"},{"tv","TV"},
        {"original","Original"},{"local","Local only"},{"tmdb-movie","TMDB movies"},{"tmdb-tv","TMDB TV"},{"tvmaze","TVmaze"},
        {"wikidata","Wikidata"},{"musicbrainz","MusicBrainz"},{"acoustid","AcoustID"},{"stream","Stream metadata"},
    }
    local snap, draft, pending, scope = {}, {}, nil, "global"
    local layout, replace = "all", false
    local themes={
        glass={background="030405",accent="AFD9FF",opacity=87,blur=true,strength=6},
        midnight={background="0B1323",accent="A7D0FF",opacity=82,blur=true,strength=8},
        graphite={background="101113",accent="C9DEDA",opacity=100,blur=false,strength=6},
    }
    local theme_names={glass="Dark glass",midnight="Midnight",graphite="Graphite",custom="Custom"}
    local function appearance_edit(key,value)
        draft[key]=value
        draft.custom=true
    end
    local edit, edit_key, edit_base, list_status
    local status, status_timer, search
    local search_number=0
    local filter=""
    local pending_filter=""
    local last_read
    local record
    local ui
    local saved_groups={
        {"Saved profiles",{"appearance","privacy","exclude","sources","tracking","panel","panel-theme","folder-filter","recognition-options"}},
        {"Saved matches",{"match","provider","tv-rule"}},
        {"Saved caches",{"cache"}},
        {"Saved AniList data",{"watch","pending","skipped","history","entry"}},
    }
    local saved_categories={
        appearance={"Appearance profiles","Card appearance saved for all files, a folder, or a file. Removing a profile restores the inherited layout."},
        privacy={"Sharing profiles","Full, generic, or hidden Discord settings saved for a scope. Removing a restriction keeps currently open files protected."},
        exclude={"Exclusions","Folders or files blocked from sharing, lookup and tracking. Removing a rule keeps currently open files protected."},
        sources={"Recognition rules","Media type or provider choices saved for a file, folder or all files."},
        tracking={"Tracking preferences","AniList mode, threshold and Ask preferences saved for each scope. Watch history has its own category."},
        panel={"Panel settings","The saved panel position and optional Discord pin handoff. Clearing this record uses the default for each."},
        ["panel-theme"]={"Panel theme","The saved panel palette, opacity and blur. Clearing this record restores Dark glass."},
        ["folder-filter"]={"Folder filter override","The saved folder filter mode or list. Removing it restores both values from rich-presence.conf."},
        ["recognition-options"]={"Optional recognition settings","Clear the switches for conditional TV folder rules and local metadata files. Saved rules and the sidecar files stay available."},
        ["tv-rule"]={"TV folder rules","Saved series identities and approved filename titles for an exact folder. Removing a folder record removes its rules. File-specific matches stay available."},
        match={"AniList corrections","Pinned AniList IDs, episode offsets and non-anime flags. Open a record to remove individual fields."},
        provider={"Other provider matches","Pinned movie, TV and music metadata. Clearing a match returns the scope to automatic lookup or its chosen provider."},
        cache={"Metadata cache","Temporary provider responses. Clearing them makes the player fetch metadata again when needed."},
        watch={"Episode timers","Real playback time for each episode and viewing cycle. Clearing a timer also clears its pending and skipped updates."},
        pending={"Pending proposals","Eligible episode updates waiting for review. Clearing these removes local proposals."},
        skipped={"Skipped episodes","Local decisions to skip an episode's update. Clearing a skip lets the episode qualify again."},
        history={"Completed updates","Local records of progress already accounted for. Your remote AniList progress is stored separately."},
        entry={"Cached list entries","The last local copy of AniList progress and status. The player refreshes it from AniList when needed."},
    }
    local function category_for(page)
        for key,category in pairs(saved_categories) do
            if page=="Saved: "..category[1] then return key end
        end
    end
    local panel_positions={"config","top-left","top-center","top-right","bottom-left","bottom-center","bottom-right"}
    local config_position="top-left"
    for _,position in ipairs(panel_positions) do
        if position~="config" and position==options.panel_position then config_position=position end
    end
    local function clock_time(ms)
        return ms and ms>0 and os.date("%d %b, %H:%M:%S",math.floor(ms/1000)) or "Not recorded"
    end
    local function duration(seconds)
        local n=math.floor(seconds)
        if n<3600 then return string.format("%02d:%02d",math.floor(n/60),n%60) end
        return string.format("%d:%02d:%02d",math.floor(n/3600),math.floor(n/60)%60,n%60)
    end
    local list_status_labels={CURRENT="Watching",PLANNING="Planning",PAUSED="Paused",DROPPED="Dropped",
        COMPLETED="Completed",REPEATING="Rewatching"}
    local tracking_mode_labels={off="Off",manual="Manual",ask="Ask",auto="Auto"}
    local ask_timing_labels={threshold="At threshold",["end"]="End of episode",leave="Before leaving"}
    local ask_positions={"top-right","top-center","top-left","bottom-right","bottom-center","bottom-left"}
    local leave_positions={"center","top-right","top-center","top-left","bottom-right","bottom-center","bottom-left"}
    local function copy(t) local r={}; for k,v in pairs(t or {}) do r[k]=v end; return r end
    local function theme_settings()
        local saved=snap.panel_theme or {}
        local preset=themes[saved.preset] and saved.preset or "glass"
        local config=copy(themes[preset])
        if options.panel_blur==false and not saved.preset then config.blur=false end
        for key,value in pairs(saved) do config[key]=value end
        return config
    end
    local cached_theme, theme_key
    local function panel_theme()
        local config=theme_settings()
        local key=table.concat({config.background,config.accent,config.opacity,tostring(config.blur),config.strength},":")
        if key==theme_key then return cached_theme end
        local function bgr(rgb) return rgb:sub(5,6)..rgb:sub(3,4)..rgb:sub(1,2) end
        local function tint(first,second,fraction)
            local out={}
            for i=1,5,2 do
                local a=tonumber(first:sub(i,i+1),16)
                local b=tonumber(second:sub(i,i+1),16)
                out[#out+1]=string.format("%02X",math.floor(a+(b-a)*fraction+.5))
            end
            return bgr(table.concat(out))
        end
        local background,accent=config.background,config.accent
        local function light(rgb)
            return .2126*tonumber(rgb:sub(1,2),16)+.7152*tonumber(rgb:sub(3,4),16)+.0722*tonumber(rgb:sub(5,6),16)>145
        end
        local readable=light(background) and "100D09" or "F7F3EF"
        theme_key=key
        cached_theme={black=bgr(background),rail=bgr(background),row=tint(background,"FFFFFF",.08),
            focus=tint(background,accent,.31),hover=tint(background,accent,.18),
            text=readable,muted=light(background) and "35302C" or "C2B8AD",
            accent=bgr(accent),ink=light(accent) and "1B1008" or "F7F3EF",rim="ABA096",
            switch=tint(background,accent,.42),hint=tint(background,"202835",.65),
            opacity=config.opacity/100,blur=config.blur,strength=config.strength}
        return cached_theme
    end
    local function request(action,fields)
        local r=fields or {}; r.action=action; r.session=snap.session; send(r)
    end
    local function edits()
        return layout=="all" and draft or {[layout.."_layout"]=draft}
    end
    local function refresh()
        local preview=ui.page=="Appearance" or ui.page=="Card preview"
        request("snapshot",{nonce="menu",page=ui.page,records=category_for(ui.page),
            replace=preview and replace and layout=="all",draft=preview and edits() or nil})
    end
    local function service(op,args)
        args=args or {}; args.op=op
        args.account=(snap.account or {}).generation
        args.notice_page=args.notice_page or ui.page
        request("service",{job=args})
    end
    local function start_search(provider,query)
        search_number=search_number+1
        search={id=tostring(search_number),provider=provider,query=query,session=snap.session}
        service("search",{provider=provider,query=query,request=search.id,notice_page="Search results"})
        if ui.page~="Search results" then ui.push("Search results") else ui.draw() end
    end
    local function clear_notice()
        if status_timer then status_timer:kill(); status_timer=nil end
        status=nil
    end
    local function notice(message,page)
        if page and page~="" and page~=ui.page then return end
        clear_notice()
        status=message
        status_timer=mp.add_timeout(3.5,function()
            status,status_timer=nil,nil
            ui.draw()
        end)
        ui.draw()
    end
    local function confirm(label,fn)
        pending={label=label,run=fn,session=snap.session,account=(snap.account or {}).generation}
        ui.push("Confirm")
    end
    local function apply(cat,values,target)
        request("apply",{category=cat,values=values,scope=target or scope,replace=cat=="appearance" and replace and layout=="all"})
        refresh()
    end
    local function pick(page) if page=="Recognition & folders" and scope=="global" then scope="file" end; if page=="Appearance" then draft={}; replace=false end; ui.push(page) end
    local function rows(page)
        local list={}
        local function row(label,fn,primary,adjust,id)
            list[#list+1]={label=label,run=fn,primary=primary,adjust=adjust,disabled=not fn,
                id=id or label:match("^(.-)   ") or label,tip=help(label,page,fn~=nil,nil,nil,id)}
            return list[#list]
        end
        local function link(label,url,description,detail,id)
            local item=row(label.."   "..(detail or url),function() options.open_url(url) end,false,nil,id)
            item.link=true
            item.tip=description.." Click or press Enter to open "..(detail and url.." " or "").."in your default browser."
        end
        local function choice(label,values,current,fn,display)
            local function step(dir)
                local idx=1
                for i,v in ipairs(values) do if v==current then idx=i; break end end
                fn(values[1+(idx-1+dir)%#values])
            end
            local item=row(label.."   "..(display or tostring(current)),function() step(1) end,false,step)
            item.tip=help(label,page,true,values,current)
        end
        local function switch(label,v,fn)
            local value=v and "On" or "Off"
            local item=row(label.."   "..value,fn)
            item.toggle=v
            item.tip=help(label,page,true,{"On","Off"},value)
        end
        local function scope_row()
            choice("Save for",{"global","folder","file"},scope,function(v) scope=v end)
        end
        local function toggle(label,key,default)
            local v=draft[key]
            local opts=snap.appearance or {}
            if v==nil and layout~="all" then v=(opts[layout.."_layout"] or {})[key] end
            if v==nil then v=opts[key] end
            if v==nil then v=default end
            switch(label,v,function() appearance_edit(key,not v); refresh() end)
        end
        local account=snap.account or {}
        local answer=snap.service or {}
        if (answer.context and answer.context~=snap.session) or (answer.generation and answer.generation~=account.generation) then answer={} end
        local entry=answer.entry
        local valid_entry=entry and entry.media==snap.match and entry.viewer==account.id and entry.session==snap.session
        local card=snap.card or {}
        local tracking=snap.tracking or {}
        local function review_update(prop)
            local base=prop.base or {}
            local episode=tostring(prop.episode)
            local progress=tostring(prop.before).." → "..episode
            local action="Update episode "..episode
            if prop.repeat_count then action=prop.start_rewatch and "Record completed rewatch" or "Finish rewatch"
            elseif prop.start_rewatch then action="Start rewatch and record episode "..episode
            elseif prop.status=="REPEATING" then action="Resume rewatch and update"
            elseif prop.status=="CURRENT" then action=base.id and "Update and switch to Watching" or "Add to Watching and update" end
            local function submit(keep)
                local message=(account.name or "AniList").." · "..((prop.title and prop.title~="") and prop.title or snap.title or "Anime")
                    .." · "..progress
                if prop.status and not keep then
                    message=message.." · "..(list_status_labels[base.status] or "Not on your list")
                        .." → "..list_status_labels[prop.status]
                elseif keep then
                    message=message.." · Keep "..(list_status_labels[base.status] or base.status).." for later updates"
                end
                if prop.repeat_count then
                    message=message.." · Rewatches "..(base["repeat"] or 0).." → "..prop.repeat_count
                end
                if prop.start_rewatch and prop.episode<prop.before then message=message.." · Reset progress for a new rewatch"
                elseif prop.episode>prop.before+1 then message=message.." · Episode gap" end
                confirm(message,function() service("accept",{proposal=prop.key,keep_status=keep}) end)
            end
            row(action.."   "..progress,function() submit(false) end,true)
            if prop.status=="CURRENT" and base.id then
                row("Update progress only   "..progress,function() submit(true) end)
            end
        end
        if page=="Menu" then
            for _,title in ipairs(sections) do local dest=title; row(dest,function() pick(dest) end) end
        elseif page=="Confirm" then
            -- Keep the entire target visible, including long folder names and titles.
            local text=pending and pending.label or "Action expired"
            local width=ui.text_columns()
            local line,units,index="",0,0
            local function add_line()
                index=index+1
                row(line,nil,false,nil,"Confirmation "..index).plain=true
                line,units="",0
            end
            for word in text:gmatch("%S+") do
                local length=0
                for ch in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do length=length+(#ch>2 and 2 or 1) end
                if units>0 and units+length+1>width then add_line() end
                if units>0 then line=line.." "; units=units+1 end
                if length<=width then line=line..word; units=units+length
                else
                    for ch in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                        local size=#ch>2 and 2 or 1
                        if units+size>width then add_line() end
                        line=line..ch; units=units+size
                    end
                end
            end
            if line~="" then add_line() end
            row("Confirm",function()
                local p=pending; pending=nil; ui.back()
                if p and p.session==snap.session and p.account==account.generation then p.run() else notice("Context changed. Review the action again.") end
            end,true)
            row("Cancel",ui.back)
        elseif page=="Now playing" then
            row("Discord   "..(snap.reason or "Waiting for mpv"))
            row("Activity   "..(card.type or "").." "..(card.name or ""))
            if card.details and card.details~=card.name then row("Details   "..card.details) end
            if card.state and card.state~=card.name then row("State   "..card.state) end
            row("Why this match?",function() ui.push("Match evidence") end)
            if snap.fingerprint_available then
                row("Fingerprint this file",function() start_search("acoustid") end)
            end
            row("View outgoing card",function() draft={}; replace=false; ui.push("Card preview") end)
            row("Correct match",function() pick("Recognition & folders") end)
            if snap.allowed and (snap.match or 0)>0 then
                row("Correct episode",function()
                    local id, session, total=snap.match, snap.session, snap.total or 0
                    ui.text("Episode number on this AniList entry",snap.episode or "",function(s)
                        if session~=snap.session or id~=snap.match then return end
                        local number=tonumber(s)
                        if not number or number~=math.floor(number) or number<1 or number>9999 or
                            (total>0 and number>total) then
                            return notice("Enter a whole episode number within the AniList entry.")
                        end
                        confirm("Use AniList episode "..number.." for this file? Saved watch time stays with its original episode.",function()
                            if snap.match==id then apply("match",{id=id,episode=number,not_anime=false},"file") end
                        end)
                    end)
                end)
            end
            row(snap.hidden_file and "Share this file" or "Hide this file",function() request("hide_file"); refresh() end)
            row("Use this window for Discord",function() request("claim"); refresh() end)
            if snap.match and snap.match>0 then row(valid_entry and ("AniList progress   "..entry.progress) or "View AniList progress",function() pick("AniList") end) end
        elseif page=="Match evidence" then
            row("Recognition   "..(snap.recognition_status or "Waiting"))
            row("Provider   "..(snap.provider or "local"))
            row("Recognition rule   "..(snap.source_scope or "configuration"))
            row("Match rule   "..(snap.match_scope or "configuration"))
            if snap.episode_review and snap.episode_review~="" then row("Review reason   "..snap.episode_review) end
        elseif page=="Card preview" then
            row("Activity   "..(card.type or "").." "..(card.name or ""))
            for _,field in ipairs({{"Details","details"},{"State","state"},{"Artwork","large_image"},{"Artwork tooltip","large_text"},
                {"Badge","small_image"},{"Badge tooltip","small_text"},{"Compact status","compact"},
                {"Artwork link","large_url"},{"Details link","details_url"},{"State link","state_url"}}) do
                local value=card[field[2]]
                if value then
                    if type(value)=="string" and value:match("^https?://") then
                        link(field[1],value,"This URL is part of the outgoing Discord card.")
                    else row(field[1].."   "..value) end
                end
            end
            for i,button in ipairs(card.buttons or {}) do
                link(button.label,button.url,"This button label and URL appear on the Discord card.",nil,"Public button "..i)
            end
        elseif page=="Appearance" then
            local opts=copy(replace and {} or snap.appearance)
            local saved=opts[layout.."_layout"] or {}
            if saved.preset then opts={} end
            for k,v in pairs(saved) do opts[k]=v end
            for k,v in pairs(draft) do opts[k]=v end
            row("Preview   "..(card.name or "mpv").." · "..(card.state or card.details or ""),function() ui.push("Card preview") end)
            scope_row()
            choice("Media layout",{"all","anime","audio","video","movie","tv","recording","stream"},layout,function(v)
                layout=v; draft={}; replace=false; refresh()
            end)
            choice("Preset",{"original","clean","detailed","private"},opts.preset or "original",function(v)
                replace=true; draft={preset=v}
                refresh()
            end,opts.custom and "Custom" or nil)
            local position=snap.panel_position
            if not position or position=="" then position="config" end
            choice("Panel position",panel_positions,position,function(v)
                if v=="config" then request("clear",{category="panel",scope="global",field="position"}); refresh()
                else apply("panel",{position=v},"global") end
            end,position=="config" and "Config · "..config_position or nil)
            for _,item in ipairs({{"Title language","language",{"original","english","romaji","native"}},
                {"Episode numbering","numbering",{"relative","original","both"}},{"Timer","timer",{"progress","remaining","session","off"}}}) do
                local key=item[2]
                local default=key=="timer" and opts.preset=="private" and "off" or item[3][1]
                choice(item[1],item[3],opts[key] or default,function(v) appearance_edit(key,v); refresh() end)
            end
            for _,item in ipairs({{"Release group","group"},{"Episode","episode"},{"Artwork","art"},{"Badge","badge"},
                {"Tooltip","tooltip"},{"Provider button","button"},{"Details","details"},{"State","state"}}) do
                local key=item[2]
                local default=not ((key=="group" and opts.preset=="clean") or
                    ((key=="art" or key=="badge" or key=="button") and opts.preset=="private"))
                toggle(item[1],key,default)
            end
            choice("Compact status",{"name","details","state"},opts.compact or "name",function(v) appearance_edit("compact",v); refresh() end)
            toggle("Episode titles","spoilers",false)
            for _,item in ipairs({{"Headline","headline"},{"Details template","details_template"},{"State template","state_template"},
                {"Artwork link","large_url"},{"Details link","details_url"},{"State link","state_url"}}) do
                local label,key=item[1],item[2]
                row(label,function() ui.text(label,opts[key] or "",function(v) appearance_edit(key,v); refresh() end) end)
            end
            row("Edit public buttons",function()
                local values={}
                for _,button in ipairs(opts.buttons or {}) do values[#values+1]=button.label.."|"..button.url end
                ui.text("Label|https://host/path (separate two buttons with a comma)",table.concat(values,","),function(v)
                appearance_edit("buttons",{})
                for label,url in v:gmatch("([^,|]+)|([^,]+)") do
                    if #draft.buttons<2 then draft.buttons[#draft.buttons+1]={label=label,url=url} end
                end
                refresh()
            end) end)
            row("Reset saved appearance",function()
                confirm("Clear appearance overrides for "..scope.." and show the inherited card",function()
                    request("clear",{category="appearance",scope=scope}); draft={}; replace=false; refresh()
                end)
            end)
            row("Panel theme",function() ui.push("Panel theme") end)
            row("Apply",function() apply("appearance",edits()); draft={}; replace=false; ui.back() end,true)
        elseif page=="Panel theme" then
            local config=theme_settings()
            local function save(values,reset)
                request("apply",{category="panel-theme",values=values,replace=reset})
                refresh()
            end
            local function customize(key,value)
                config[key]=value
                config.preset="custom"
                save(config,true)
            end
            local preset=config.preset or "glass"
            choice("Panel theme preset",{"glass","midnight","graphite","custom"},preset,function(v)
                if v=="custom" then config.preset=v; save(config,true)
                else save({preset=v},true) end
            end,theme_names[preset])
            for _,field in ipairs({{"Background color","background"},{"Accent color","accent"}}) do
                local name,key=field[1],field[2]
                row(name.."   #"..config[key],function()
                    ui.text(name.." (hex RGB)","#"..config[key],function(value)
                        local rgb=value:match("^#?(%x%x%x%x%x%x)$")
                        if not rgb then return notice("Enter six hex digits, for example #030405.") end
                        customize(key,rgb:upper())
                    end)
                end)
            end
            local function amount(name,key,low,high,suffix)
                row(name.."   "..config[key]..suffix,function()
                    ui.text(name.." ("..low.." to "..high..")",config[key],function(value)
                        local n=tonumber(value)
                        if not n or n~=math.floor(n) or n<low or n>high then
                            return notice("Enter a whole number from "..low.." to "..high..".")
                        end
                        customize(key,n)
                    end)
                end)
            end
            amount("Panel opacity","opacity",40,100,"%")
            switch("Background blur",config.blur,function() customize("blur",not config.blur) end)
            if config.blur then amount("Blur strength","strength",2,12," px") end
            row("Restore panel theme defaults",function()
                request("clear",{category="panel-theme"}); refresh()
            end)
            row("Cancel",ui.back)
        elseif page=="Recognition & folders" then
            scope_row()
            row("Folder filters",function() ui.push("Folder filters") end)
            local current=(snap.sources or {}).source or "auto"
            local label=current
            for _,source in ipairs(sources) do if source[1]==current then label=source[2]; break end end
            if scope=="folder" and not snap.has_local_folder then
                row("Open a local file to set its folder source")
            else
                row("Media recognition   "..label,function() ui.push("Choose source") end)
            end
            row("Source rule   "..(snap.source_scope or "configuration"))
            local recognition=snap.recognition_options or {}
            switch("TV folder rules",recognition.tv_rules==true,function()
                apply("recognition-options",{tv_rules=not recognition.tv_rules},"global")
            end)
            switch("Local metadata files",recognition.sidecar_metadata==true,function()
                apply("recognition-options",{sidecar_metadata=not recognition.sidecar_metadata},"global")
            end)
            switch("Ask before fingerprinting",recognition.confirm_fingerprint==true,function()
                apply("recognition-options",{confirm_fingerprint=not recognition.confirm_fingerprint},"global")
            end)
            row("Provider settings and credits",function() ui.push("Providers") end)
            row("AniList search",function() ui.text("Search anime","",function(q)
                start_search("anilist",q)
            end) end)
            row("Enter AniList ID or URL",function() ui.text("AniList ID or URL","",function(s)
                local id=tonumber(s:match("^%d+$") or s:match("^https://anilist%.co/anime/(%d+)"))
                if id then confirm("Use AniList "..id.." for "..scope,function() apply("match",{id=id,not_anime=false}) end) end
            end) end)
            local offset=(snap.correction or {}).offset or 0
            row("Episode offset   "..offset,function()
                ui.text("Episode offset",tostring(offset),function(s)
                    local value=tonumber(s)
                    if value and value==math.floor(value) and value>=-9999 and value<=9999 then apply("match",{offset=value})
                    else notice("Enter a whole number from -9999 to 9999.") end
                end)
            end)
            row("Mark as non-anime",function() confirm("Skip anime matching for "..scope,function() apply("match",{not_anime=true}) end) end)
            row("Refresh match",function() request("refresh_match"); refresh() end)
            for _,provider in ipairs({{"tmdb-movie","TMDB movies"},{"tmdb-tv","TMDB TV"},{"tvmaze","TVmaze"},{"musicbrainz","MusicBrainz"}}) do
                local id,name=provider[1],provider[2]
                row("Search "..name,function() ui.text("Search "..name,"",function(q)
                    start_search(id,q)
                end) end)
            end
            row("Fingerprint this file",function()
                start_search("acoustid")
            end)
        elseif page=="Choose source" then
            row("Inherit recognition source",function()
                confirm("Remove the recognition override for "..scope,function()
                    request("clear",{category="sources",scope=scope}); refresh(); ui.back()
                end)
            end)
            for _,source in ipairs(sources) do
                local value,label=source[1],source[2]
                row(label,function()
                    confirm("Use "..label.." for "..scope,function()
                        apply("sources",{source=value}); ui.back()
                    end)
                end)
            end
        elseif page=="Providers" then
            link("AniList","https://anilist.co/","Supplies public anime titles, artwork and sequel links. Sign-in is only needed for list features.","Anime metadata")
            link("TMDB","https://www.themoviedb.org/","Supplies movie and TV titles, episode metadata and posters. The packaged default uses the shared service.",
                options.tmdb_key~="" and "Personal token" or "Shared service")
            row("This product uses the TMDB API but is not endorsed or certified by TMDB.",nil,false,nil,"TMDB attribution")
            link("TVmaze","https://www.tvmaze.com/","Supplies aired episode order and artwork as a TV fallback. Its data is licensed under CC BY-SA.","TV metadata · CC BY-SA")
            link("Wikidata","https://www.wikidata.org/","Supplies film titles and release years if TMDB cannot resolve a movie.","Movie fallback")
            link("MusicBrainz","https://musicbrainz.org/","Matches recording and album tags. The plugin checks artist credits and runtime before selecting a recording.","Music metadata")
            link("Cover Art Archive","https://coverartarchive.org/","Supplies artwork for identified MusicBrainz releases and release groups.","Album artwork")
            link("AcoustID","https://acoustid.org/","Identifies local audio using a fingerprint. Only the fingerprint and duration are sent. The package includes an application key.",
                options.bundled_fpcalc and "Fingerprinting included" or "Uses fpcalc on PATH")
        elseif page=="Search results" then
            local result=answer.search or {}
            if not search or search.session~=snap.session then
                row("Playback changed. Start a new search.")
            elseif result.id~=search.id then row("Searching…")
            elseif result.state=="failed" then
                row("Search failed   "..(result.error or "Provider unavailable"))
                row("Retry search",function() start_search(search.provider,search.query) end)
            else
                local current=search
                local tv=current.provider=="tmdb-tv" or current.provider=="tvmaze"
                for _,r in ipairs(result.results or {}) do
                    local hit=r
                    row(hit.title,function()
                        local target=tv and "file" or scope
                        confirm("Use "..hit.title.." for "..target,function()
                            if search~=current then return end
                            service("select",{candidate=hit,scope=target,request=current.id})
                        end)
                    end)
                    if tv and snap.has_local_folder and (snap.recognition_options or {}).tv_rules then
                        local function save_rule(dedicated)
                            local prompt=dedicated and ("Does this folder contain only "..hit.title.."? Files with only an episode number can use this series.")
                                or ("Save a folder rule for "..hit.title.."?")
                            confirm(prompt,function()
                                if search~=current then return end
                                service("select",{candidate=hit,scope=dedicated and "tv-dedicated" or "tv-rule",request=current.id})
                            end)
                        end
                        local item=row("Use "..hit.title.." for matching files in this folder",function() save_rule(false) end)
                        item.tip="Save this series for files in this exact folder that share the approved series title. Each file still needs its own episode number or air date. Unclear or conflicting titles use Automatic recognition. Other shows can have their own rules."
                        item=row("Dedicated folder for "..hit.title,function() save_rule(true) end)
                        item.tip="Use only for a folder dedicated to this one series. A file named S02E04 can use this rule. A file with a conflicting title or identifier uses regular recognition. Only one series per folder can claim files with no title."
                    end
                end
                if #(result.results or {})==0 then row("No results") end
            end
        elseif page=="Privacy & windows" then
            local status_row=row("Discord status   "..(snap.reason or "Waiting"))
            status_row.tip="Read only. Shows whether this window can publish a full or generic card, or why sharing is paused or hidden. Other windows may publish their own cards."
            local lookup_row=row("Online metadata   "..(snap.allowed and "Allowed" or "Blocked"))
            lookup_row.tip="Read only. When allowed, supported providers receive the search title and relevant tags or episode numbers. When blocked, new lookups and AniList requests for this file are stopped. Private sessions and folder exclusions take priority."
            local tracking_row=row("AniList tracking   "..(snap.track_allowed and "Eligible" or "Off or blocked"))
            tracking_row.tip="Read only. Shows whether current permissions allow counting watch time. The AniList page also shows whether this particular episode is confirmed and can update the list."
            row("Local watch history",function() ui.push("Saved AniList data") end)
            switch("Release idle Discord pin",snap.yield_idle_pin==true,function()
                request("idle_pin",{enabled=not snap.yield_idle_pin}); refresh()
            end)
            scope_row()
            row("Folder filters",function() ui.push("Folder filters") end)
            choice("Discord",{"full","generic","hidden"},(snap.privacy or {}).mode or "full",function(v)
                confirm("Set "..scope.." sharing to "..v,function() apply("privacy",{mode=v}) end)
            end)
            row(snap.private and "End private session" or "Start private session",function()
                request("private",{enabled=not snap.private}); refresh()
            end)
            row("Exclude this folder",function() confirm("Block lookups, tracking and Discord for this folder?",function()
                apply("exclude",{blocked=true},"folder")
            end) end)
            row("Hide Discord for a time",function()
                ui.text("Minutes to hide (0 to resume)","60",function(value)
                    local minutes=tonumber(value)
                    if minutes and minutes==math.floor(minutes) and minutes>=0 and minutes<=1440 then
                        request("hide_minutes",{minutes=minutes}); refresh()
                    end
                end)
            end)
            row(snap.hidden_until_exit and "End window hide" or "Hide Discord until this window closes",function()
                request("hide_until_exit",{enabled=not snap.hidden_until_exit}); refresh()
            end)
            row(snap.pinned and "Return to last-resumed window" or "Pin this window for Discord",function()
                request(snap.pinned and "unpin" or "pin"); refresh()
            end)
            row("Use this window",function() request("claim"); refresh() end)
            switch("Track while hidden",tracking.without_sharing==true,function()
                apply("tracking",{without_sharing=not tracking.without_sharing})
            end)
        elseif page=="Folder filters" then
            local settings=snap.folder_filter or {}
            local folders=settings.folders or {}
            local modes={disabled="Disabled",whitelist="Whitelist",blacklist="Blacklist"}
            local function update(fields) request("folder_filter",fields); refresh() end
            local function set_folders(paths) update({folders=paths}) end
            local function add(path)
                path=path:match("^%s*(.-)%s*$"):gsub('^"(.*)"$',"%1")
                if not (path:match("^%a:[/\\]") or path:match("^%a:$") or path:match("^[/\\][/\\]") or path:sub(1,1)=="/") then
                    notice("Enter an absolute folder path."); return
                end
                local paths=copy(folders)
                paths[#paths+1]=path
                set_folders(paths)
            end
            local mode=settings.mode or "disabled"
            row("Filter source   "..(settings.inherited==false and "Saved in panel" or "Configuration"))
            choice("Filter mode",{"disabled","whitelist","blacklist"},mode,function(v)
                confirm("Switch the folder filter to "..modes[v].." for all mpv windows?",function() update({mode=v}) end)
            end,modes[mode])
            local exception=settings.exception or "off"
            local access=exception~="off" and "Temporary exception" or settings.passes and "Allowed by filter" or "Blocked by filter"
            if not settings.current or settings.current=="" then access="Open a local file" end
            row("Current folder access   "..access)
            if settings.current and settings.current~="" then
                row("Current folder   "..settings.current)
                if exception~="off" then
                    row("End temporary exception",function() request("folder_exception",{mode="off"}); refresh() end)
                elseif not settings.passes then
                    row("Allow this file until it closes",function() request("folder_exception",{mode="file"}); refresh() end)
                    row("Bypass the filter in this window",function()
                        confirm("Allow local files outside the folder filter until this mpv window closes?",function()
                            request("folder_exception",{mode="window"}); refresh()
                        end)
                    end)
                end
                local listed=false
                for _,path in ipairs(folders) do if path==settings.current then listed=true; break end end
                if not listed then
                    row("Add current folder",function()
                        confirm("Add "..settings.current.." to the "..(mode=="blacklist" and "block list" or "folder list").."?",function() add(settings.current) end)
                    end)
                end
            end
            row("Listed folders   "..#folders,function() ui.push("Listed folders") end)
            row("Add folder path",function() ui.text("Absolute folder path","",add) end)
            if settings.inherited==false then
                row("Restore conf filter",function()
                    confirm("Restore the folder filter mode and list from rich-presence.conf?",function() update({mode="config"}) end)
                end)
            end
        elseif page=="Listed folders" then
            local folders=(snap.folder_filter or {}).folders or {}
            if #folders==0 then row("No folders listed") end
            for i,path in ipairs(folders) do
                local entry=row("Folder "..i.."   "..path,function()
                    confirm("Remove "..path.." from the folder filter list?",function()
                        local paths={}
                        for _,folder in ipairs(folders) do if folder~=path then paths[#paths+1]=folder end end
                        request("folder_filter",{folders=paths}); refresh()
                    end)
                end)
                entry.tip="Remove this directory from the list after reviewing the full path. In Whitelist mode this removes access. In Blacklist mode it removes a block."
            end
        elseif page=="AniList" then
            if account.name and tonumber(account.id) then
                local username=account.name:match("^[A-Za-z0-9_-]+$") and account.name or tostring(account.id)
                link("Account","https://anilist.co/user/"..username,
                    "Open the connected account's AniList profile.",account.name)
                list[#list].avatar=account.avatar and account.avatar.medium
            else
                row("Account   Not signed in")
            end
            if account.name then
                local item=row("Connection   "..(account.persistent and "Saved on this device" or "This session only"))
                item.tip="Read only. Saved connections use the operating system's credential store. Session-only connections expire when the helper or mpv exits."
            end
            row(account.expired and "Reconnect to AniList" or account.name and "Switch or reconnect account" or "Connect account",function() service("connect") end)
            if answer.signin then
                local item=row("Cancel browser sign-in",function() request("cancel_connect",{id=answer.signin}) end)
                item.tip="Cancel this browser attempt and discard the pending connection. A previously connected account stays active."
            end
            if not account.name then
                row("Connect for this session",function() service("connect",{session_only=true}) end)
            end
            if account.name then
                row("Refresh list entry",function() service("read") end)
                row("Disconnect",function() ui.push("Disconnect account") end)
            end
            row("Anime   "..((snap.match or 0)>0 and (snap.title or "Unknown title") or "No match"))
            row("Playing episode   "..(snap.episode and snap.episode~="" and snap.episode or "Unknown"))
            local watch=snap.episode_watch or {}
            local elapsed=watch.elapsed or 0
            local mode=tracking.mode or "off"
            local watch_status
            if not account.id then watch_status="Connect AniList"
            elseif mode=="off" then watch_status="Tracking is off"..(elapsed>0 and (" · "..duration(elapsed).." saved") or "")
            elseif not snap.allowed then watch_status="Tracking blocked"
            elseif (snap.match or 0)==0 then watch_status="No anime match"
            elseif snap.episode_review and snap.episode_review~="" then watch_status="Episode needs review"
            elseif not snap.episode or snap.episode=="" then watch_status="No episode number"
            elseif not snap.watch_episode then watch_status="Episode needs review"
            elseif elapsed<=0 then watch_status="No time recorded yet"
            else watch_status=duration(elapsed) end
            row("Episode watch time   "..watch_status)
            if tracking.coverage then
                local item=row("Unique footage watched   "..duration(watch.coverage or 0))
                item.tip="Read only. Shows how much distinct footage was played while this option was enabled. Replaying a scene counts once here. The episode watch timer and AniList threshold still use real elapsed playback time."
            end
            if snap.episode_review and snap.episode_review~="" then
                row("Episode type   "..snap.episode_review)
            end
            if elapsed>0 then
                row("Watch started   "..clock_time(watch.first_watched))
                row("Last watched   "..clock_time(watch.last_watched))
            end
            if answer.read_state=="loading" then row("List status   Loading…") end
            if answer.read_state=="offline" and not valid_entry then row("List status   Offline · no confirmed progress") end
            if valid_entry then
                row(entry.id and ("List entry   "..entry.progress.." / "..(snap.total>0 and snap.total or "?")..
                    " · "..(list_status_labels[entry.status] or entry.status or "?")..(answer.offline and " · Offline" or "")) or "List status   Not on your list")
                local function bump(n) if not edit_base then edit_base=copy(entry) end; edit=math.max(0,(edit or entry.progress)+n); if snap.total>0 then edit=math.min(edit,snap.total) end end
                local draft_row=row("Episodes watched   "..tostring(edit or entry.progress),nil,false,bump)
                draft_row.stepper,draft_row.disabled=true,false
                draft_row.tip=help(draft_row.label,page,true)
                local function submit(target)
                    local message=account.name.." · "..snap.title.." · "..entry.progress.." → "..target
                    if list_status then message=message.." · set status to "..list_status end
                    if not entry.id then message="Create entry · "..message end
                    if target>entry.progress+1 then message="Episode gap · "..message end
                    local base=edit_base or copy(entry)
                    confirm(message,function() service("write",{base=base,target=target,status=list_status}); list_status=nil; edit=nil; edit_base=nil end)
                end
                choice("Status on Apply",{"unchanged","CURRENT","COMPLETED","REPEATING","PAUSED","DROPPED","PLANNING"},
                    list_status or "unchanged",function(v) list_status=v~="unchanged" and v or nil end)
                row("Apply progress",function() submit(edit or entry.progress) end,true)
                row("Reset progress edit",function() edit=entry.progress; edit_base=copy(entry) end)
                if snap.watch_episode and tonumber(snap.episode) then row("Mark current episode watched",function() submit(tonumber(snap.episode)) end) end
            end
            scope_row()
            choice("Tracking",{"off","manual","ask","auto"},mode,function(v) apply("tracking",{mode=v}) end,tracking_mode_labels[mode])
            if mode=="ask" then
                local timing=tracking.ask_timing or "threshold"
                choice("Ask timing",{"threshold","end","leave"},timing,function(v)
                    apply("tracking",{ask_timing=v})
                end,ask_timing_labels[timing])
                choice("Ask prompt position",ask_positions,
                    tracking.ask_position or "top-right",function(v) apply("tracking",{ask_position=v}) end)
            end
            if mode=="ask" or mode=="auto" then
                local position=tracking.ask_leave_position or "center"
                choice("Before leaving position",leave_positions,position,
                    function(v) apply("tracking",{ask_leave_position=v}) end,position=="center" and "Center" or position)
                local seconds=tracking.ask_timeout or 30
                row("Ask prompt timeout   "..(seconds==0 and "Never" or seconds.." seconds"),function()
                    ui.push("Ask prompt timeout")
                end)
            end
            switch("Resume unfinished time",tracking.resume~=false,function()
                apply("tracking",{resume=tracking.resume==false})
            end)
            switch("Measure unique footage",tracking.coverage==true,function()
                apply("tracking",{coverage=not tracking.coverage})
            end)
            switch("Keep offline proposals",tracking.keep_pending==true,function()
                apply("tracking",{keep_pending=not tracking.keep_pending})
            end)
            row("Pending updates   "..#(snap.pending or {}),function() ui.push("Pending updates") end)
            switch("Rewatch tracking",tracking.rewatch==true,function() apply("tracking",{rewatch=not tracking.rewatch}) end)
            if tracking.rewatch then
                row("Start new viewing cycle",function()
                    confirm("Start a new local viewing cycle for "..(snap.title or "this anime")..
                        "? Watch counters start fresh and pending updates for this entry are cleared.",function() service("rearm") end)
                end)
            end
            local threshold=tracking.threshold or 15
            row("Threshold   "..threshold.." minutes",function()
                ui.text("Minimum elapsed minutes",tostring(threshold),function(s)
                    local value=tonumber(s)
                    if value and value==math.floor(value) and value>=1 and value<=1440 then apply("tracking",{threshold=value})
                    else notice("Enter a whole number from 1 to 1440 minutes.") end
                end)
            end)
            if answer.proposal and snap.allowed and snap.watch_episode and answer.proposal.media==snap.match
                and answer.proposal.episode==tonumber(snap.episode) then
                local p=answer.proposal
                review_update(p)
                row("Later",ui.back); row("Skip this episode",function() service("skip",{proposal=p.key}) end)
            end
        elseif page=="Disconnect account" then
            if not account.name then row("Account   Not signed in"); return list end
            row("Account   "..account.name)
            row("Keep local watch history",function()
                confirm("Disconnect "..account.name.."? Keep local watch history and cancel queued updates.",function()
                    service("disconnect",{notice_page="AniList"}); ui.back()
                end)
            end)
            row("Forget local watch history",function()
                confirm("Disconnect "..account.name.." and forget local history? This clears local watch times, cached progress and pending updates.",function()
                    service("disconnect",{forget_history=true,notice_page="AniList"}); ui.back()
                end)
            end)
        elseif page=="Pending updates" then
            if #(snap.pending or {})>0 then
                local item=row("Filter updates",function() ui.text("Filter by title or episode",pending_filter,function(value) pending_filter=value end) end)
                item.tip="Search pending proposals by anime title or episode number. Filtering changes the display only. Open the matching episode to verify and apply an update."
                if pending_filter~="" then row("Clear filter",function() pending_filter="" end) end
            end
            local visible=0
            for _,item in ipairs(snap.pending or {}) do
                local prop=item
                local label=(prop.title~="" and prop.title or ("AniList "..prop.media)).." · Episode "..prop.episode
                if label:lower():find(pending_filter:lower(),1,true) then
                    visible=visible+1
                    row(label,nil,false,nil,"Proposal "..prop.key)
                    if prop.offline then row("Waiting to refresh remote progress")
                    elseif snap.allowed and snap.watch_episode and prop.media==snap.match and prop.episode==tonumber(snap.episode) then
                        review_update(prop)
                    else row("Play this episode to apply its update") end
                    row("Skip "..label,function() confirm("Skip "..label,function() service("skip",{proposal=prop.key}) end) end)
                end
            end
            if #(snap.pending or {})==0 then row("No pending updates") end
            if #(snap.pending or {})>0 and visible==0 then row("No updates match the filter") end
        elseif page=="Ask prompt timeout" then
            local function set_timeout(value)
                apply("tracking",{ask_timeout=value})
                ui.back()
            end
            local seconds=tracking.ask_timeout or 30
            for _,value in ipairs({0,15,30,60}) do
                local label=value==0 and "Never" or value.." seconds"
                local item=row(label..(seconds==value and "   Current" or ""),function() set_timeout(value) end)
                item.tip=value==0 and "Leave the prompt open until you choose an action, Later, or the close button."
                    or "Dismiss the prompt after "..value.." seconds and keep its update in Pending updates."
            end
            row("Custom timeout",function()
                ui.text("Dismiss after 5 to 300 seconds",tostring(seconds>0 and seconds or 30),function(s)
                    local value=tonumber(s)
                    if value and value==math.floor(value) and value>=5 and value<=300 then set_timeout(value)
                    else notice("Enter a whole number from 5 to 300 seconds.") end
                end)
            end)
        elseif page=="Saved data" then
            local counts=snap.record_counts or {}
            for _,group in ipairs(saved_groups) do
                local name,count=group[1],0
                for _,category in ipairs(group[2]) do count=count+(counts[category] or 0) end
                row(name.."   "..count,function() filter=""; ui.push(name) end)
            end
            row("Reset everything",function() confirm("Clear local profiles, matches, caches and watch history, disconnect AniList, and restore the defaults from rich-presence.conf.",function() service("reset") end) end)
        elseif category_for(page) then
            local cat=category_for(page)
            local label,description=saved_categories[cat][1],saved_categories[cat][2]
            local count=(snap.record_counts or {})[cat] or 0
            local shown=0
            local function clear(scope)
                local suffix=scope and (" ("..scope..")") or " (all "..count..")"
                confirm("Clear "..label:lower()..suffix.."? "..description,function()
                    service("clear",{category=cat,scope=scope,notice_page=page})
                end)
            end
            if count>0 then
                row("Filter records"..(filter~="" and "   "..filter or ""),function()
                    ui.text("Filter this category",filter,function(v) filter=v end)
                end)
                if filter~="" then row("Clear search",function() filter="" end) end
                if cat=="cache" or cat=="watch" or cat=="pending" or cat=="skipped" or cat=="history" or cat=="entry" then
                    row("Clear all   "..count,function() clear() end).tip=description.." This applies to every record in this category."
                end
            end
            for _,item in ipairs(snap.records or {}) do
                if item.category==cat and ((item.label or "").." "..item.scope):lower():find(filter:lower(),1,true) then
                    shown=shown+1
                    local title,value=label,item.scope
                    if cat=="cache" then
                        local kind=item.label or ""
                        title=kind:gsub("^v%d+:",""):gsub("^music%-v%d+:","Music · "):gsub(":"," · ")
                        if title=="" then title="Cached result" end
                        value=item.expires and item.expires>0 and
                            (item.expires<os.time() and "Expired" or "Expires "..os.date("%d %b",math.floor(item.expires))) or "Cached"
                    elseif cat=="watch" or cat=="history" or cat=="pending" or cat=="skipped" or cat=="entry" then
                        local _,media,episode,cycle=item.scope:match("^(%d+)/(%d+)/(%d+)/(%d+)$")
                        if media then title,value="AniList "..media,"Episode "..episode.." · Cycle "..(tonumber(cycle)+1)
                        else
                            media=item.scope:match("^%d+/(%d+)$")
                            if media then title,value="AniList "..media,label end
                        end
                    end
                    row(title.."   "..value,function()
                        if cat=="match" then record=item; ui.push("Saved match")
                        else clear(item.scope) end
                    end,false,nil,cat..":"..item.scope).tip=description.." Record key "..item.scope
                end
            end
            if shown==0 then row(count==0 and "No saved records" or filter=="" and "Loading records…" or "No matching records") end
        elseif page=="Saved profiles" or page=="Saved matches" or page=="Saved caches" or page=="Saved AniList data" then
            local counts=snap.record_counts or {}
            for _,group in ipairs(saved_groups) do
                if group[1]==page then
                    for _,key in ipairs(group[2]) do
                        local name,description=saved_categories[key][1],saved_categories[key][2]
                        row(name.."   "..(counts[key] or 0),function() filter=""; ui.push("Saved: "..name) end).tip=description
                    end
                    break
                end
            end
        elseif page=="Saved match" and record then
            row("Scope   "..record.scope)
            for _,field in ipairs({{"id","Pinned AniList ID"},{"not_anime","Non-anime flag"},{"offset","Episode offset"},{"episode","Corrected episode"}}) do
                local key,label=field[1],field[2]
                if record.fields[key]~=nil then
                    row(label.."   "..tostring(record.fields[key]),function()
                        local target=record.scope
                        confirm("Forget "..label.." for "..target..". Other fields stay saved.",function()
                            service("clear",{category="match",scope=target,field=key}); record.fields[key]=nil
                        end)
                    end)
                end
            end
        elseif page=="Diagnostics" then
            row("Sharing   "..(snap.reason or "Waiting")); row("SDK   "..(snap.sdk or "Waiting"))
            if (snap.last_published or 0)>0 then row("Last Discord publish   "..clock_time(snap.last_published)) end
            row("Configuration   "..(snap.configured and "Received" or "Waiting"))
            if options.helper_status then row("Python helper   "..options.helper_status()) end
            row("Publisher   "..(snap.owner and "This window" or "Other window"))
            row("Lookup   "..(snap.allowed and "Allowed" or "Blocked"))
            row("Recognition status   "..tostring(snap.recognition_status or "Waiting"))
            row("Recognition source   "..tostring(snap.provider or "local"))
            row("Source rule   "..(snap.source_scope or "configuration"))
            row("Match rule   "..(snap.match_scope or "configuration"))
            row("Appearance rule   "..(snap.appearance_scope or "configuration"))
            row("Tracking   "..(snap.track_allowed and "Eligible" or "Off or excluded"))
            if answer.last_read then row("Last list read   "..os.date("%H:%M:%S",math.floor(answer.last_read))) end
            if answer.last_write then row("Last list write   "..os.date("%H:%M:%S",math.floor(answer.last_write))) end
            row("AniList ID   "..tostring(snap.match or 0)); row("Preset   "..((snap.appearance or {}).preset or "original"))
            row("Account operation   "..(answer.message or "None"))
        end
        if status then row(status,nil,false,nil,"Message") end
        return list
    end
    ui=make_sheet({sections=sections,rows=rows,refresh=refresh,notice=notice,scale=options.menu_scale,
        avatar=options.avatar,backdrop=options.backdrop,theme=panel_theme,
        animate=options.menu_animations,help=help,changed=clear_notice,position=function()
            return snap.panel_position and snap.panel_position~="" and snap.panel_position or config_position
        end,
        leaving=function(page) if page=="Appearance" then draft={}; replace=false end end,
        closed=function() draft={}; edit=nil; edit_base=nil; list_status=nil; pending=nil; clear_notice(); if ui.terminal then mp.set_property("term-status-msg",ui.old_term or "") end end})
    ui.update=function(value)
        if not ui.open then return end
        local key=tostring(value.session).."/"..tostring(value.match).."/"..tostring((value.account or {}).generation)
        if key~=edit_key then edit=nil; edit_base=nil; list_status=nil; pending=nil; draft={}; edit_key=key end
        snap=value
        if ui.page=="AniList" and value.allowed and (value.match or 0)>0 and (value.account or {}).id and last_read~=key then
            last_read=key; service("read",{quiet=true})
        end
        ui.draw()
    end
    return ui
end
