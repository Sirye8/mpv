-- SPDX-License-Identifier: AGPL-3.0-or-later
local assdraw = require("mp.assdraw")
local ok_input, input = pcall(require, "mp.input")
-- ASS colors are BGR. The video output composites the alpha under the whole sheet.
local default_theme = {black="050403", rail="050403", row="1B1816", hover="40352B", focus="594636",
    text="F7F3EF", muted="C2B8AD", accent="FFD9AF", ink="1B1008", rim="ABA096",
    switch="5F5348", hint="18130F"}
local utf8_char = "[%z\1-\127\194-\244][\128-\191]*"
local function escape(text)
    return (text:gsub("\\", "\\\239\187\191"):gsub("{", "\\{"):gsub("}", "\\}"))
end
local function advance(ch)
    if #ch>=3 then return .88 end
    if ch:match("[ ilI1%.,:;'!|]") then return .23 end
    if ch:match("[MWmw@%%&]") then return .64 end
    if ch:match("%u") then return .49 end
    return .42
end
local function measure(text,size)
    local width=0
    for ch in text:gmatch(utf8_char) do width=width+advance(ch) end
    return math.ceil(width*size)
end
local function display(text,size,space)
    text=tostring(text or ""):gsub("[%c]", " ")
    local overflow=measure(text,size)-space
    return {full=escape(text),overflow=overflow>0 and overflow+3 or 0}
end
local function fit(text,size,space)
    text=tostring(text or ""):gsub("[%c]", " ")
    if measure(text,size)<=space then return escape(text) end
    local chars, remaining={}, math.max(0,space-size)
    for ch in text:gmatch(utf8_char) do
        remaining=remaining-advance(ch)*size
        if remaining<0 then break end
        chars[#chars+1]=ch
    end
    return escape(table.concat(chars)).."…"
end

local function alpha(opacity)
    return string.format("%02X", math.floor(255*(1-opacity)+.5))
end

local function box(ass, x,y,r,b, color, opacity, radius, rim)
    ass:new_event(); ass:an(7); ass:pos(0,0)
    ass:append("{\\shad0\\bord"..(rim and 1 or 0).."\\1c&H"..color.."&\\1a&H"..alpha(opacity).."&"..
        (rim and "\\3c&H"..default_theme.rim.."&\\3a&H"..alpha(rim).."&" or "").."}")
    ass:draw_start(); ass:round_rect_cw(x,y,r,b,radius or 8); ass:draw_stop()
end

local function label(ass, x,y, text, size, color, opacity, align, bold, clip)
    ass:new_event(); ass:an(align or 7); ass:pos(x,y)
    ass:append("{\\fnSegoe UI\\fs"..size.."\\b"..(bold and 1 or 0).."\\bord0\\shad0\\q2\\1c&H"..color..
        "&\\alpha&H"..alpha(opacity).."&"..(clip or "").."}"..text)
end

return function(model)
    local theme=default_theme
    local row_step, row_height = model.compact and 28 or 32, model.compact and 25 or 29
    local mouse_section = model.compact and "rich-presence-ask" or "rich-presence-panel"
    local ui = {open=false, page="Menu", memory={}, stack={}, hits={}}
    local overlay, layout, refresh_timer, toast_timer, hover_timer, animation_timer
    local last_frame, last_terminal
    local keys, editing, pressed, hovered, tooltip, drag = {}
    local stop_edit,controls
    local scale = 1
    local motion = {shell=0, page=1, focus=1, hover=0, hint=0, scroll=0}
    local tweens = {}

    local function dimensions()
        local w,h = mp.get_osd_size()
        if not w or w<=0 or not h or h<=0 then return end
        local factor = math.max(.76, math.min(h/740, 2.4)) * (model.scale or 1)
        factor = math.min(factor, w/300, h/380)
        return w/factor,h/factor,factor
    end

    local function columns(w,h)
        local margins = mp.get_property_native("user-data/osc/margins",{})
        local min_left,max_right = 12+w*(margins.l or 0),w-12-w*(margins.r or 0)
        local min_top = math.max(48,12+h*(margins.t or 0))
        local max_bottom = math.min(h*.86,h-12-h*(margins.b or 0))
        local span = max_right-min_left
        local wide = not model.compact and span>=716 and h>=560 and max_bottom-min_top>=88+row_step*#model.sections and ui.page~="Menu"
        local width = math.min(span,model.compact and 360 or wide and 670 or 438)
        local position = model.position and model.position() or "top-left"
        local left = min_left
        if position:match("%-right$") then left=max_right-width
        elseif position=="center" or position:match("%-center$") then left=(min_left+max_right-width)/2 end
        return left,left+width,left+(wide and 220 or 0),wide,position,min_top,max_bottom
    end

    function ui.text_columns(size)
        local w,h = dimensions()
        if not w then return 72 end
        local _,right,pane = columns(w,h)
        return math.max(3,math.floor((right-pane-32)/((size or 15)*.44)))
    end

    local function remove_overlay()
        if overlay then overlay:remove(); overlay=nil end
        last_frame=nil
    end

    local function paint(ass, w,h)
        local frame = w..":"..h..ass.text
        if frame==last_frame then return end
        overlay = overlay or mp.create_osd_overlay("ass-events")
        if model.compact then overlay.z=1 end
        overlay.res_x,overlay.res_y,overlay.data = w,h,ass.text
        overlay:update()
        last_frame=frame
    end

    local function draw_cell(ass,item,cell,x,y,r,size,color,opacity,right,bold)
        -- The clip follows the actual cell. A font-width estimate only decides
        -- alignment and travel, so text that fits is never shortened here.
        local align_right=right and cell.overflow==0
        local shift=hovered==item.key and math.min(cell.overflow,math.floor(motion.scroll)) or 0
        local clip=string.format("\\clip(%d,%d,%d,%d)",math.ceil(x),math.floor(y),math.floor(r),math.ceil(y+size+8))
        label(ass,align_right and r or x-shift,y,cell.full,size,color,opacity,align_right and 9 or nil,bold,clip)
    end

    local function render()
        if (editing and editing.dialog) or not layout or motion.shell<=0 then return end
        local ass = assdraw.ass_new()
        theme=model.theme and model.theme() or default_theme
        local left,top,right,bottom,pane = layout.left,layout.top,layout.right,layout.bottom,layout.pane
        local shell = motion.shell
        local content = shell*(.58+.42*motion.page)
        local offset = layout.direction*math.floor(6*(1-motion.page)+.5)
        local rise = math.floor(4*(1-shell)+.5)
        box(ass,left+1,top+4,right+1,bottom+5,theme.rail,.34*shell,16)
        box(ass,left,top,right,bottom,theme.black,(theme.opacity or .87)*shell,16,.34*shell)
        if layout.wide then
            box(ass,left+5,top+5,pane-5,bottom-5,theme.rail,.34*shell,12)
            label(ass,left+14,top+13,"Rich Presence",16,theme.accent,shell,nil,true)
            for _,item in ipairs(layout.nav) do
                local active = item.title==layout.page
                local highlight = hovered==item.key and motion.hover or 0
                if active or highlight>0 then
                    box(ass,item.x,item.y,item.r,item.b,theme.focus,(active and .82 or .58*highlight)*shell,8)
                end
                if active then
                    box(ass,item.x+4,item.y+7,item.x+7,item.b-7,theme.accent,.92*shell,1.5)
                end
                draw_cell(ass,item,item.display,item.x+13,item.y+5,item.r-8,15,active and theme.text or theme.muted,shell)
            end
        end
        label(ass,pane+14+offset,top+10+rise,layout.title,20,theme.text,content,nil,true)
        box(ass,pane+9,top+39,right-9,top+40,theme.rim,.22*shell,.5)
        for _,item in ipairs(layout.rows) do
            local is_pressed = pressed==item.key and not item.disabled
            local highlight = hovered==item.key and motion.hover or 0
            local focus = item.focused and motion.focus or 0
            local inset = is_pressed and 1 or 0
            local x,y,r,b = item.x+inset,item.y+inset,item.r-inset,item.b-inset
            if item.plain then
                draw_cell(ass,item,item.display,x+5+offset,y+5+rise,item.r-9,15,theme.text,content)
            elseif item.primary or is_pressed then
                box(ass,x,y,r,b,theme.accent,(is_pressed and .81 or .96)*content)
            else
                box(ass,x,y,r,b,theme.row,(item.disabled and .35 or .61)*content)
                local emphasis = math.max(.76*focus,.52*highlight)
                if emphasis>0 then box(ass,x,y,r,b,theme.focus,emphasis*content) end
            end
            if not item.plain and item.focused and not item.primary and not is_pressed then
                box(ass,x+4,y+7,x+7,b-7,theme.accent,focus*content,1.5)
            end
            local color = (item.primary or is_pressed) and theme.ink or (item.disabled and theme.muted or theme.text)
            if item.editor and editing then
                box(ass,x+2,y+2,r-2,b-2,theme.hover,content,7,.65)
                local value=editing.selected and editing.value or editing.value:sub(1,editing.cursor).."│"..editing.value:sub(editing.cursor+1)
                local left=x+12
                local right=r-12
                local shift=editing.selected and 0 or math.max(0,measure(editing.value:sub(1,editing.cursor),15)-(right-left-18))
                if editing.selected then box(ass,left-3,y+4,math.min(right,left+measure(value,15)+4),b-4,theme.focus,content,4) end
                local clip=string.format("\\clip(%d,%d,%d,%d)",math.ceil(left),math.floor(y),math.floor(right),math.ceil(b))
                label(ass,left-shift,y+5,escape(value),15,theme.text,content,nil,false,clip)
            elseif item.stepper then
                label(ass,(x+r)/2,y+5+rise,item.caption.."  "..item.value_text,15,theme.text,content,8,true)
                for _,button in ipairs(item.stepper) do
                    local active=hovered==button.key and motion.hover or 0
                    box(ass,button.x+2,y+2,button.r-2,b-2,theme.hover,
                        (pressed==button.key and .95 or .46+.42*active)*content,7)
                    label(ass,(button.x+button.r)/2,y+2+rise,button.title,19,theme.accent,content,8,true)
                end
            elseif not item.plain then
                draw_cell(ass,item,item.display,x+13+offset,y+5+rise,item.label_right,15,color,content,false,item.primary)
            end
            if item.value then
                local color = item.primary and theme.ink or (item.disabled and theme.muted or theme.accent)
                draw_cell(ass,item,item.value,item.label_right+12,y+6+rise,item.value_right,14,color,content,true)
            end
            if item.fn and item.toggle==nil and (item.adjust or not item.value or item.link) and not item.primary then
                label(ass,r-10,y+4+rise,item.link and "↗" or "›",16,theme.accent,.8*content,9)
            end
            if item.toggle~=nil then
                local sx = r-46
                local knob = sx+(item.toggle and 20 or 3)
                box(ass,sx,y+6,sx+36,y+23,item.toggle and theme.accent or theme.switch,content,8)
                box(ass,knob,y+8,knob+13,y+21,item.toggle and theme.ink or theme.text,content,6)
            end
        end
        for _,item in ipairs(layout.footer) do
            local emphasis = hovered==item.key and motion.hover or 0
            local inset = pressed==item.key and 1 or 0
            box(ass,item.x+inset,item.y+inset,item.r-inset,item.b-inset,
                item.primary and theme.accent or theme.hover,(item.primary and .95 or .38+.48*emphasis)*shell)
            label(ass,item.x+12,item.y+5+inset,item.title,14,item.primary and theme.ink or theme.accent,shell,nil,true)
        end
        if layout.scroll then
            local scroll = layout.scroll
            box(ass,right-6,scroll.start,right-2,scroll.finish,theme.rim,.25*shell,2)
            box(ass,right-6,scroll.first,right-2,scroll.last,theme.accent,(drag and 1 or .8)*shell,2)
        end
        if tooltip and motion.hint>0 then
            local tip = tooltip
            local opacity = shell*motion.hint
            local y = tip.y + math.floor(4*(1-motion.hint)+.5)
            box(ass,tip.x,y,tip.x+tip.width,y+tip.height,theme.hint,.97*opacity,12,.45*opacity)
            for _,line in ipairs(tip.lines) do
                local line_y=line.y-tip.scroll
                if line_y>=8 and line_y+line.size+3<=tip.height-(tip.max_scroll>0 and 25 or 4) then
                    label(ass,tip.x+line.x,y+line_y,line.text,line.size,line.color,opacity,nil,line.bold)
                end
            end
            if tip.max_scroll>0 then
                label(ass,tip.x+12,y+tip.height-21,"Scroll to read the full tooltip",12,theme.accent,opacity)
            end
        end
        paint(ass,layout.w,layout.h)
    end

    local function stop_animation()
        if animation_timer then animation_timer:kill(); animation_timer=nil end
    end

    local function tick()
        local now = mp.get_time()
        for key,tween in pairs(tweens) do
            local progress = math.min(1,(now-tween.start)/tween.duration)
            local eased=tween.linear and progress or 1-(1-progress)^3
            motion[key] = tween.from+(tween.to-tween.from)*eased
            if progress==1 then
                motion[key]=tween.to
                tweens[key]=nil
            end
        end
        if motion.hint==0 then tooltip=nil end
        if not ui.open and motion.shell==0 then
            remove_overlay()
            layout=nil
        else
            render()
        end
        if not next(tweens) then stop_animation() end
    end

    local function animate(key, from, to, duration, linear)
        if model.animate==false or from==to then
            motion[key],tweens[key] = to,nil
            return
        end
        motion[key] = from
        tweens[key] = {from=from,to=to,start=mp.get_time(),duration=duration,linear=linear}
        if not animation_timer then animation_timer=mp.add_periodic_timer(1/60,tick) end
    end

    local function clear_hover(immediate)
        if hover_timer then hover_timer:kill(); hover_timer=nil end
        hovered=nil
        motion.hover,tweens.hover=0,nil
        motion.scroll,tweens.scroll=0,nil
        if immediate or motion.hint==0 or model.animate==false then
            motion.hint,tweens.hint,tooltip=0,nil,nil
        else
            animate("hint", motion.hint, 0, .10)
        end
    end

    local function wrap(text, width, size)
        local lines,line,used = {},"",0
        for word in text:gmatch("%S+") do
            local length=measure(word,size)
            if line~="" and used+length+size*.23>width then
                lines[#lines+1]=line
                line,used="",0
            end
            if length>width then
                for ch in word:gmatch(utf8_char) do
                    local pixels=advance(ch)*size
                    if used+pixels>width and line~="" then
                        lines[#lines+1]=line
                        line,used="",0
                    end
                    line,used=line..ch,used+pixels
                end
            else
                if line~="" then line,used=line.." ",used+size*.23 end
                line,used=line..word,used+length
            end
        end
        if line~="" then lines[#lines+1]=line end
        return lines
    end

    local function make_tip(target)
        local options = type(target.tip)=="table" and target.tip.options
        local width = math.min(options and 378 or 318,layout.w-24)
        local lines, height = {}, 8
        local function line(text,x,y,size,color,bold)
            lines[#lines+1]={text=escape(text),x=x,y=y,size=size,color=color,bold=bold}
        end
        for _,value in ipairs(wrap(target.caption or target.title,width-28,15)) do
            line(value,12,height,15,theme.accent,true)
            height=height+19
        end
        if target.value_text then
            for _,value in ipairs(wrap(target.value_text,width-28,14)) do
                line(value,12,height,14,theme.text)
                height=height+18
            end
            height=height+4
        end
        if options then
            line("Options",12,height,12,theme.muted,true)
            height=height+19
            local column = math.min(122,math.floor(width*.39))
            local description_width = width-column-12
            for _,option in ipairs(options) do
                local color = option.selected and theme.accent or theme.text
                local name = option.label:sub(1,1):upper()..option.label:sub(2):gsub("-", " ")
                local marker = option.selected and "• " or ""
                local option_label=wrap(marker..name,column-16,13)
                for i,value in ipairs(option_label) do
                    line(value,12,height+(i-1)*16,13,color,true)
                end
                local detail = wrap(option.detail,description_width,13)
                for i,value in ipairs(detail) do
                    line(value,column,height+(i-1)*16,13,theme.text)
                end
                height=height+math.max(20,16*math.max(#detail,#option_label)+3)
            end
        else
            for _,value in ipairs(wrap(target.tip,width-24,14)) do
                line(value,12,height,14,theme.text)
                height=height+18
            end
        end
        height=height+8
        local max_scroll=0
        local max_height=math.max(80,layout.max_bottom-layout.min_top-4)
        if height>max_height then
            max_scroll=height-max_height+25
            height=max_height
        end
        local space_right = layout.w-layout.right>=width+20
        local space_left = layout.left>=width+20
        local beside = space_right or space_left
        local x = space_right and layout.right+8 or space_left and layout.left-width-8 or
            math.min(layout.left,layout.w-width-12)
        local ceiling = math.max(layout.min_top,layout.max_bottom-height-4)
        local y = target.y
        if not beside then
            if layout.bottom+8<=ceiling then y=layout.bottom+8
            elseif layout.top-height-8>=layout.min_top then y=layout.top-height-8
            else y=target.y-height-8 end
        end
        return {x=x,y=math.max(layout.min_top,math.min(y,ceiling)),width=width,height=height,
            key=target.key,lines=lines,max_scroll=max_scroll,scroll=0}
    end

    local function unbind()
        for _,id in ipairs(keys) do mp.remove_key_binding(id) end
        keys = {}
        mp.disable_key_bindings(mouse_section)
    end

    local function bind(key, fn, opts)
        local id = (model.compact and "rich_presence_ask_" or "rich_presence_sheet_") .. key
        mp.add_forced_key_binding(key,id,fn,opts)
        keys[#keys+1] = id
    end

    function ui.close()
        if not ui.open then return end
        ui.open=false
        if editing and editing.dialog and input.terminate then input.terminate() end
        if model.avatar then model.avatar() end
        if model.backdrop then model.backdrop() end
        clear_hover(true)
        if refresh_timer then refresh_timer:kill(); refresh_timer=nil end
        mp.unobserve_property(ui.draw)
        mp.unobserve_property(ui.mouse_moved)
        unbind()
        ui.stack,ui.hits,pressed,editing,drag = {},{},nil,nil,nil
        model.closed()
        tweens={}
        if layout and overlay then animate("shell",motion.shell,0,.14) end
        if not tweens.shell then
            stop_animation()
            remove_overlay()
            layout=nil
            motion.shell=0
        end
    end

    local function show_page(page, direction)
        if editing and stop_edit then stop_edit(false) end
        if model.changed then model.changed() end
        if layout then layout.direction=direction end
        ui.page=page
        pressed,drag=nil,nil
        clear_hover(true)
        animate("page",0,1,.16)
        model.refresh()
        ui.draw()
    end

    function ui.push(page)
        ui.stack[#ui.stack+1] = ui.page
        show_page(page,1)
    end

    function ui.back()
        if model.leaving then model.leaving(ui.page) end
        local page = table.remove(ui.stack)
        if page then show_page(page,-1) else ui.close() end
    end

    function ui.draw()
        if not ui.open or (editing and editing.dialog) then return end
        local rows = model.rows(ui.page)
        if editing then
            local found=false
            for i,row in ipairs(rows) do
                if row.id==editing.id then
                    rows[i]={id=row.id,label=editing.prompt,editor=true}
                    found=true
                    break
                end
            end
            if not found then rows[#rows+1]={id=editing.id,label=editing.prompt,editor=true} end
        end
        local mem = ui.memory[ui.page] or {focus=1,top=1}
        ui.memory[ui.page]=mem
        if mem.id then
            for i,row in ipairs(rows) do if row.id==mem.id then mem.focus=i; break end end
        end
        mem.focus=math.max(1,math.min(#rows,mem.focus))
        mem.id=rows[mem.focus] and rows[mem.focus].id
        local w,h,factor = dimensions()
        if not w then
            if model.avatar then model.avatar() end
            if model.backdrop then model.backdrop() end
            if layout then
                clear_hover(true)
                mp.set_mouse_area(0,0,0,0,mouse_section)
                ui.hits,layout={},nil
                remove_overlay()
            end
            local lines={ui.page}
            for i,row in ipairs(rows) do lines[#lines+1]=(i==mem.focus and "> " or "  ")..row.label end
            if model.compact then lines[#lines+1]=model.footer().." · Esc" end
            local frame=table.concat(lines,"\n")
            if frame~=last_terminal then mp.set_property("term-status-msg",frame); last_terminal=frame end
            ui.terminal=true
            return
        end
        if ui.terminal then
            mp.set_property("term-status-msg",ui.old_term)
            ui.terminal,last_terminal=false,nil
        end
        scale=factor
        local left,right,pane,wide,position,min_top,max_bottom = columns(w,h)
        local available = math.max(1,math.floor((math.min(h*(model.compact and .76 or .57)-min_top,max_bottom-min_top)-88)/row_step))
        local shown = math.max(1,math.min(#rows,available))
        local height = 88+row_step*math.max(shown,wide and #model.sections or 0)
        local top = position:match("^bottom%-") and math.max(min_top,max_bottom-height) or min_top
        if position=="center" then top=math.max(min_top,math.min((h-height)/2,max_bottom-height)) end
        local bottom = top+height
        local bounds = {math.floor(left*scale),math.floor(top*scale),math.ceil(right*scale),math.ceil(bottom*scale)}
        if model.backdrop then
            theme=model.theme and model.theme() or default_theme
            model.backdrop(bounds,16*scale,theme.blur,theme.strength)
        end
        local bounds_key = table.concat(bounds,":")
        if not layout or layout.bounds~=bounds_key then
            mp.set_mouse_area(bounds[1],bounds[2],bounds[3],bounds[4],mouse_section)
            clear_hover(true)
            pressed=nil
        end
        local previous = layout
        layout = {w=math.floor(w),h=math.floor(h),left=left,top=top,right=right,bottom=bottom,pane=pane,wide=wide,
            min_top=min_top,max_bottom=max_bottom,
            title=fit(editing and editing.prompt or (ui.page=="Menu" and "Rich Presence" or ui.page),20,right-pane-(model.compact and 57 or 36)),
            page=ui.page,direction=previous and previous.direction or 1,
            bounds=bounds_key,focus=mem.id,nav={},rows={},footer={}}
        ui.hits={}
        local function hit(group,x,y,r,b,id,key,fn,title,tip)
            local item={x=x,y=y,r=r,b=b,id=id,key=key,fn=fn,title=title,tip=tip}
            group[#group+1]=item
            ui.hits[#ui.hits+1]=item
            return item
        end
        if wide then
            for i,page in ipairs(model.sections) do
                local y=top+44+(i-1)*row_step
                local key="nav"..i
                local item=hit(layout.nav,left+6,y,pane-6,y+row_height,key,key,function()
                    if model.leaving then model.leaving(ui.page) end
                    ui.stack={"Menu"}
                    show_page(page,1)
                end,page,model.help and model.help(page))
                item.display=display(page,15,item.r-item.x-21)
            end
        end
        mem.top=math.max(1,math.min(mem.top,math.max(1,#rows-available+1)))
        if mem.reveal then
            mem.top=math.max(mem.focus-available+1,math.min(mem.top,mem.focus))
            mem.reveal=nil
        end
        for i=mem.top,math.min(#rows,mem.top+available-1) do
            local row=rows[i]
            local y=top+44+(i-mem.top)*row_step
            local key="row:"..(row.id or i)
            local item
            if row.stepper then
                local buttons={}
                for _,button in ipairs({{-1,"−","Decrease the episode count by one.",pane+19,pane+60},
                    {1,"+","Increase the episode count by one.",right-55,right-11}}) do
                    hit(buttons,button[4],y,button[5],y+row_height,i,key..button[2],
                        function() row.adjust(button[1]) end,button[2],button[3].." Use Apply progress to review and save.")
                end
                item=hit(layout.rows,pane+8,y,right-8,y+row_height,i,key,nil,row.label,row.tip)
                item.stepper=buttons
            else
                item=hit(layout.rows,pane+8,y,right-8,y+row_height,i,key,not row.disabled and row.run or nil,row.label,row.tip)
            end
            item.focused,item.disabled,item.primary,item.toggle,item.adjust,item.plain = mem.focus==i,row.disabled,row.primary,row.toggle,row.adjust,row.plain
            item.editor=row.editor
            item.avatar=row.avatar
            local title,value=row.label:match("^(.-)   (.+)$")
            item.caption,item.value_text,item.link=title or row.label,value,row.link
            if item.stepper then value=nil end
            local label_left=item.x+(row.plain and 5 or 13)
            local inset=row.avatar and 52 or (row.adjust or row.link or (item.fn and not value)) and 26 or 11
            item.label_right=item.r-inset
            if row.toggle~=nil then
                item.label_right=item.r-49
            elseif value then
                item.value_right=item.label_right
                local space=item.value_right-label_left-12
                local title_width=measure(title,15)+6
                local value_width=measure(value,14)+4
                local value_space=math.min(value_width,space-math.min(title_width,math.floor(space*.48)))
                item.label_right=item.value_right-value_space-12
                item.value=display(value,14,value_space)
            end
            item.display=display(item.caption,15,item.label_right-label_left-6)
        end
        if model.avatar then
            local avatar
            for _,item in ipairs(layout.rows) do
                if item.avatar then avatar=item; break end
            end
            model.avatar(avatar and avatar.avatar,avatar and math.floor((avatar.r-47)*scale),
                avatar and math.floor((avatar.y+3)*scale),avatar and math.max(16,math.floor(23*scale)))
        end
        if editing then
            local mid=(pane+right)/2
            hit(layout.footer,pane+8,bottom-35,mid-3,bottom-7,"cancel","cancel",function() stop_edit(false) end,"Cancel","Discard this edit.")
            local save=hit(layout.footer,mid+3,bottom-35,right-8,bottom-7,"save","save",function() stop_edit(true) end,"Done","Use the entered value.")
            save.primary=true
        elseif model.compact then
            hit(layout.footer,right-38,top+6,right-8,top+34,"close","close",ui.close,"×",
                "Dismiss this prompt and keep the update for later.")
            hit(layout.footer,pane+8,bottom-35,right-8,bottom-7,"later","later",ui.close,model.footer(),
                "Keep this update for later and let mpv continue.")
        elseif ui.page=="Appearance" then
            local mid=(pane+right)/2
            hit(layout.footer,pane+8,bottom-35,mid-3,bottom-7,"cancel","cancel",ui.back,"Cancel","Discard the unsaved preview.")
            for _,row in ipairs(rows) do
                if row.label=="Apply" then
                    local apply=hit(layout.footer,mid+3,bottom-35,right-8,bottom-7,"apply","apply",row.run,"Apply",row.tip)
                    apply.primary=true
                    break
                end
            end
        else
            local title=ui.page=="Menu" and "Close" or "Back"
            hit(layout.footer,pane+8,bottom-35,right-8,bottom-7,"back","back",ui.back,title,
                ui.page=="Menu" and "Close the panel." or "Return to the previous page.")
        end
        if #rows>shown then
            local size=shown*row_step-3
            local first=top+45+size*(mem.top-1)/#rows
            layout.scroll={first=first,last=first+size*shown/#rows,
                start=top+45, finish=top+45+size, limit=#rows-shown+1, page_size=shown}
        end
        if previous and previous.page==ui.page and previous.focus~=mem.id then animate("focus",.4,1,.11) end
        if tooltip then
            local updated
            for _,target in ipairs(ui.hits) do
                if target.key==tooltip.key and target.tip then updated=make_tip(target); break end
            end
            if updated then updated.scroll=math.min(tooltip.scroll,updated.max_scroll) end
            tooltip=updated
        end
        render()
    end

    local function focus(delta)
        local mem=ui.memory[ui.page]
        clear_hover(false)
        mem.id=nil
        mem.focus=mem.focus+delta
        mem.reveal=true
        ui.draw()
    end

    local function activate(delta)
        local mem=ui.memory[ui.page]
        mem.reveal=true
        local row=model.rows(ui.page)[mem.focus]
        if row and not row.disabled then
            if delta and row.adjust then row.adjust(delta) elseif not delta and row.run then row.run() end
            ui.draw()
        end
    end

    local function scroll_to(value)
        local mem=ui.memory[ui.page]
        local top=math.max(1,math.min(layout.scroll.limit,value))
        if top==mem.top then return end
        mem.top=top
        clear_hover(true)
        ui.draw()
    end

    local function pointer(event)
        if not ui.open or (editing and editing.dialog) then return end
        local x,y=mp.get_mouse_pos()
        x,y=x/scale,y/scale
        local bar=layout and layout.scroll
        if drag then
            if event=="up" or drag.page~=ui.page or not bar then
                drag=nil
                render()
            elseif event=="hover" then
                local travel=bar.finish-bar.start-(bar.last-bar.first)
                if travel>0 then scroll_to(1+math.floor((y-bar.start-drag.offset)/travel*(bar.limit-1)+.5)) end
            end
            return
        end
        if bar and x>=layout.right-8 and x<layout.right and y>=bar.start and y<=bar.finish then
            if event=="down" then
                pressed=nil
                if y>=bar.first and y<bar.last then
                    drag={page=ui.page,offset=y-bar.first}
                    clear_hover(true)
                    render()
                else
                    scroll_to(ui.memory[ui.page].top+(y<bar.first and -bar.page_size or bar.page_size))
                end
            elseif event=="hover" and hovered then
                clear_hover(true)
                render()
            end
            return
        end
        local target
        for _,item in ipairs(ui.hits) do
            if x>=item.x and x<item.r and y>=item.y and y<item.b then target=item; break end
        end
        if editing and target and target.key~="save" and target.key~="cancel" then target=nil end
        local key=target and target.key
        if event=="hover" then
            if key==hovered then return end
            clear_hover(false)
            hovered=key
            if target then animate("hover",.15,1,.11) end
            if target and target.tip then
                hover_timer=mp.add_timeout(.33,function()
                    hover_timer=nil
                    for _,item in ipairs(ui.hits) do
                        if item.key==hovered then
                            if item.tip then
                                tooltip=make_tip(item)
                                animate("hint",.18,1,.13)
                            end
                            local distance=math.max(item.display and item.display.overflow or 0,item.value and item.value.overflow or 0)
                            if distance>0 and model.animate~=false then
                                animate("scroll",0,distance,math.max(.25,math.min(14,distance/74)),true)
                            end
                            render()
                            break
                        end
                    end
                end)
            end
        elseif event=="down" then
            pressed=target and target.fn and key or nil
            if pressed and type(target.id)=="number" then
                ui.memory[ui.page].focus=target.id
                ui.memory[ui.page].id=nil
                ui.draw()
                return
            end
        elseif event=="up" then
            local clicked=pressed
            pressed=nil
            if target and clicked==key and target.fn then
                clear_hover(true)
                target.fn()
                ui.draw()
                return
            end
        end
        render()
    end

    ui.mouse_moved=function(_,position)
        if position and position.hover==false then drag=nil; clear_hover(false); render()
        else pointer("hover") end
    end
    local function scroll(delta)
        if editing then return end
        if tooltip and tooltip.key==hovered and tooltip.max_scroll>0 then
            tooltip.scroll=math.max(0,math.min(tooltip.max_scroll,tooltip.scroll+delta*72))
            render()
        elseif layout and layout.scroll then
            local mem=ui.memory[ui.page]
            mem.wheel=(mem.wheel or 0)+delta*3
            local steps=mem.wheel>=0 and math.floor(mem.wheel) or math.ceil(mem.wheel)
            mem.wheel=mem.wheel-steps
            if steps~=0 then scroll_to(mem.top+steps) end
        end
    end
    local bindings={
        {"wheel_up",function() scroll(-1) end},
        {"wheel_down",function() scroll(1) end},
        {"mbtn_left",nil,function() pointer("down") end,function() pointer("up") end},
        {"mbtn_left_dbl","ignore"},
    }
    if mp.register_script_message and mp.get_script_name then
        local name=mouse_section.."-wheel"
        mp.add_key_binding(nil,name,function(event)
            if event.event=="press" or event.event=="down" then
                scroll((event.arg=="up" and -1 or 1)*(event.scale or 1))
            end
        end,{complex=true,scalable=true})
        bindings[1][2]="script-binding "..mp.get_script_name().."/"..name.." up"
        bindings[2][2]="script-binding "..mp.get_script_name().."/"..name.." down"
    end
    mp.set_key_bindings(bindings,mouse_section,"force")

    controls=function()
        if not model.compact or not dimensions() then
            bind("HOME",function() focus(-100000) end); bind("END",function() focus(100000) end)
            bind("UP",function() focus(-1) end,{repeatable=true})
            bind("DOWN",function() focus(1) end,{repeatable=true})
            bind("LEFT",function() activate(-1) end); bind("RIGHT",function() activate(1) end)
            bind("ENTER",function() activate() end)
        end
        bind("ESC",model.compact and ui.close or ui.back)
        mp.enable_key_bindings(mouse_section,"allow-hide-cursor")
    end

    stop_edit=function(save)
        local session=editing
        if not session then return end
        editing=nil
        unbind()
        if ui.open then controls(); ui.draw() end
        if save then session.done(session.value) end
    end

    function ui.text(prompt, value, done)
        local mem=ui.memory[ui.page]
        local session={prompt=prompt,value=tostring(value or ""),done=done,id=mem and mem.id}
        editing=session
        clear_hover(true)
        pressed=nil
        tweens={}
        stop_animation()
        motion.shell,motion.page,motion.focus=1,1,1
        unbind()
        if dimensions() and session.id then
            session.cursor=#session.value
            session.selected=true
            local function insert(value)
                value=(value or ""):gsub("[%c]"," ")
                if value=="" then return end
                if session.selected then session.value,session.cursor,session.selected="",0,false end
                if #session.value+#value>8192 then return end
                local i=session.cursor
                session.value=session.value:sub(1,i)..value..session.value:sub(i+1)
                session.cursor=i+#value
                render()
            end
            local function boundary(direction)
                local i=session.cursor
                repeat i=i+direction until i<=0 or i>=#session.value or
                    not session.value:sub(i+1,i+1):match("[\128-\191]")
                return math.max(0,math.min(#session.value,i))
            end
            local function move(i)
                session.cursor,session.selected=i,false
                render()
            end
            local function erase(direction)
                if session.selected then
                    session.value,session.cursor,session.selected="",0,false
                else
                    local edge=boundary(direction)
                    local first,last=math.min(edge,session.cursor),math.max(edge,session.cursor)
                    session.value=session.value:sub(1,first)..session.value:sub(last+1)
                    session.cursor=first
                end
                render()
            end
            bind("any_unicode",function(event)
                if event.event~="up" and event.key_text then insert(event.key_text) end
            end,{complex=true,repeatable=true})
            bind("Ctrl+v",function() insert(mp.get_property("clipboard/text","")) end)
            bind("Shift+Insert",function() insert(mp.get_property("clipboard/text","")) end)
            bind("Ctrl+a",function() session.selected=true; render() end)
            bind("LEFT",function() move(session.selected and 0 or boundary(-1)) end,{repeatable=true})
            bind("RIGHT",function() move(session.selected and #session.value or boundary(1)) end,{repeatable=true})
            bind("HOME",function() move(0) end)
            bind("END",function() move(#session.value) end)
            bind("BS",function() erase(-1) end,{repeatable=true})
            bind("DEL",function() erase(1) end,{repeatable=true})
            bind("ENTER",function() stop_edit(true) end)
            bind("ESC",function() stop_edit(false) end)
            mp.enable_key_bindings(mouse_section,"allow-hide-cursor")
            mem.reveal=true
            ui.draw()
            return
        end
        session.dialog=true
        remove_overlay()
        if not ok_input then stop_edit(false); model.notice("Text input unavailable."); return end
        input.get({prompt=prompt,default_text=value or "",submit=function(s)
            if editing==session then done(s) end
        end,closed=function()
            if editing~=session then return end
            editing=nil
            if ui.open then controls(); ui.draw() end
        end})
    end

    function ui.toast(message,page)
        if ui.open then model.notice(message,page); return end
        local w,h=mp.get_osd_size()
        if not w or w<=0 or h<=0 then mp.msg.info(message); return end
        if toast_timer then toast_timer:kill() end
        tweens={}
        stop_animation()
        layout=nil
        motion.shell=0
        local ass=assdraw.ass_new()
        local res=math.floor(w*720/h)
        local right=res-16
        local left=math.max(8,right-460)
        box(ass,left,644,right,704,theme.black,.92,12,.34)
        label(ass,left+16,662,fit(message,18,right-left-32),18,theme.text,1)
        paint(ass,res,720)
        toast_timer=mp.add_timeout(4,function()
            if not ui.open then remove_overlay() end
            toast_timer=nil
        end)
    end

    function ui.show(page)
        if ui.open then
            if page then ui.stack={"Menu"}; show_page(page,1) else ui.close() end
            return
        end
        if toast_timer then toast_timer:kill(); toast_timer=nil; remove_overlay() end
        ui.old_term=mp.get_property("term-status-msg","")
        ui.terminal,last_terminal=false,nil
        ui.open=true
        ui.page=page or "Menu"
        ui.stack=page and {"Menu"} or {}
        motion.page,motion.focus=1,1
        animate("shell",math.max(.20,motion.shell),1,.18)
        controls()
        mp.observe_property("osd-dimensions","native",ui.draw)
        mp.observe_property("user-data/osc/margins","native",ui.draw)
        mp.observe_property("mouse-pos","native",ui.mouse_moved)
        model.refresh()
        refresh_timer=mp.add_periodic_timer(1,model.refresh)
        ui.draw()
    end
    return ui
end
