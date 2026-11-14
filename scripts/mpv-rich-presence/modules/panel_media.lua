-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(options, modules, interpreter, utils)
    local shader=utils.join_path(modules,"panel-blur.glsl")
    local parameters={"rp_left","rp_top","rp_right","rp_bottom","rp_radius","rp_strength"}
    local active,geometry=false,nil
    local function stop_blur()
        if not active then return end
        active,geometry=false,nil
        mp.commandv("change-list","glsl-shaders","remove",shader)
        for _,key in ipairs(parameters) do
            mp.commandv("change-list","glsl-shader-opts","remove","panel-blur/"..key)
        end
    end
    options.backdrop=function(bounds,radius,enabled,strength)
        if not bounds or not enabled or mp.get_property("current-vo")~="gpu-next" then
            stop_blur()
            return
        end
        local d=mp.get_property_native("osd-dimensions") or {}
        if not d.w or not d.h then stop_blur(); return end
        local l,t,r,b=d.ml or 0,d.mt or 0,d.mr or 0,d.mb or 0
        if bounds[3]<=l or bounds[4]<=t or bounds[1]>=d.w-r or bounds[2]>=d.h-b then
            stop_blur()
            return
        end
        local values={bounds[1]-l,bounds[2]-t,bounds[3]-l,bounds[4]-t,radius,strength or 6}
        local key=table.concat(values,",")
        if geometry==key then return end
        local args=mp.get_property_native("glsl-shader-opts") or {}
        for i,name in ipairs(parameters) do
            args["panel-blur/"..name]=string.format("%.2f",values[i])
        end
        if not mp.set_property_native("glsl-shader-opts",args) then return end
        if not active then
            active=not not mp.commandv("change-list","glsl-shaders","append",shader)
            if not active then
                for _,name in ipairs(parameters) do
                    mp.commandv("change-list","glsl-shader-opts","remove","panel-blur/"..name)
                end
            end
        end
        if active then geometry=key end
    end

    local avatar_url,pixels,job,displayed,rectangle,retry_after
    local avatar_file
    local avatar_id=58
    local function remove_avatar()
        if displayed then mp.commandv("overlay-remove",avatar_id); displayed=nil end
    end
    local function show_avatar()
        if not rectangle or not pixels then return end
        local key=table.concat(rectangle,":")
        if displayed==key then return end
        local x,y,size=unpack(rectangle)
        if mp.commandv("overlay-add",avatar_id,x,y,avatar_file,0,"bgra",64,64,256,size,size) then
            displayed=key
        end
    end
    options.avatar=function(url,x,y,size)
        if type(url)~="string" or not url:match("^https://s4%.anilist%.co/") then
            rectangle=nil
            remove_avatar()
            return
        end
        rectangle={x,y,size}
        if url==avatar_url and (pixels or job or mp.get_time()<(retry_after or 0)) then
            show_avatar()
            return
        end
        if job then mp.abort_async_command(job) end
        remove_avatar()
        avatar_url,pixels=url,nil
        job=mp.command_native_async({name="subprocess",args={interpreter,"-I",
            utils.join_path(modules,"avatar.py"),url,mp.get_property("pid")},
            playback_only=false,capture_stdout=true,capture_stderr=true},function(_,result)
            if avatar_url~=url then return end
            job=nil
            retry_after=mp.get_time()+60
            if not result or result.status~=0 or #(result.stdout or "")~=16384 then return end
            avatar_file=avatar_file or utils.join_path(os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp",
                "mpv-rich-presence-avatar-"..mp.get_property("pid")..".bgra")
            local file=io.open(avatar_file,"wb")
            if not file then return end
            local written=file:write(result.stdout)
            file:close()
            if written then pixels=true; show_avatar() end
        end)
    end
    mp.register_event("shutdown",function()
        if job then mp.abort_async_command(job) end
        remove_avatar()
        if avatar_file then os.remove(avatar_file) end
        stop_blur()
    end)
end
