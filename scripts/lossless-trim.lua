local mp = require 'mp'
local utils = require 'mp.utils'

local start_time = nil
local end_time = nil
local osd_timer = nil

-- Format seconds as HH-MM-SS.FF
local function format_time(seconds)
    if not seconds then return "--:--:--" end
    local hrs = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    return string.format("%02d-%02d-%05.2f", hrs, mins, secs)
end

-- Show current trim range in OSD
local function update_osd()
    if not start_time and not end_time then return end
    local msg = string.format("Trim Range: Start = %s | End = %s",
        format_time(start_time), format_time(end_time))
    mp.osd_message(msg, 1)
end

local function start_osd_timer()
    if osd_timer then osd_timer:kill() end
    osd_timer = mp.add_periodic_timer(0.5, update_osd)
end

local function reset_trim()
    start_time = nil
    end_time = nil
    if osd_timer then
        osd_timer:kill()
        osd_timer = nil
    end
    mp.osd_message("Trim times reset.")
end

-- Map audio codec to file extension
local function get_audio_extension(codec)
    local map = {
        aac = ".aac",
        mp3 = ".mp3",
        vorbis = ".ogg",
        opus = ".opus",
        flac = ".flac",
        alac = ".m4a",
        pcm_s16le = ".wav",
        eac3 = ".eac3",
        ac3 = ".ac3"
    }
    return map[codec] or ".audio"
end

-- Main trim function
local function trim_media(is_audio_only)
    if not start_time or not end_time then
        mp.osd_message("Start and end time must be set.")
        return
    end

    if end_time <= start_time then
        mp.osd_message("End time must be after start time.")
        return
    end

    local path = mp.get_property("path")
    if not path then
        mp.osd_message("No file loaded.")
        return
    end

    local codec = mp.get_property("audio-codec-name")
    local ext = path:match("^.+(%..+)$")
    local name = path:match("^(.*)%.[^%.]+$")
    local suffix = string.format("_%s-%s", format_time(start_time), format_time(end_time))

    local output_path
    if is_audio_only then
        local audio_ext = get_audio_extension(codec)
        output_path = name .. suffix .. audio_ext
    else
        output_path = name .. suffix .. ext
    end

    local args = {
        "ffmpeg",
        "-ss", tostring(start_time),
        "-i", path,
        "-to", tostring(end_time - start_time),
    }

    if is_audio_only then
        table.insert(args, "-map")
        table.insert(args, "0:a")
        table.insert(args, "-c:a")
        table.insert(args, "copy")
    else
        table.insert(args, "-c")
        table.insert(args, "copy")
    end

    table.insert(args, "-avoid_negative_ts")
    table.insert(args, "make_zero")
    table.insert(args, output_path)

    mp.osd_message((is_audio_only and "Exporting trimmed audio..." or "Trimming video..."))
    local res = utils.subprocess({ args = args, cancellable = false })

    if res.status == 0 then
        mp.osd_message("Saved to: " .. output_path .. "\nTrim times reset.")
        reset_trim()
    else
        mp.osd_message("FFmpeg failed!")
    end
end

-- Key bindings
mp.add_key_binding("ctrl+1", "mark_trim_start", function()
    start_time = mp.get_property_number("time-pos")
    if start_time then
        mp.osd_message("Trim start set: " .. format_time(start_time))
        start_osd_timer()
    end
end)

mp.add_key_binding("ctrl+2", "mark_trim_end", function()
    end_time = mp.get_property_number("time-pos")
    if end_time then
        mp.osd_message("Trim end set: " .. format_time(end_time))
        start_osd_timer()
    end
end)

mp.add_key_binding("ctrl+3", "export_trimmed_video", function()
    trim_media(false)
end)

mp.add_key_binding("ctrl+4", "export_trimmed_audio", function()
    trim_media(true)
end)

mp.add_key_binding("ctrl+0", "reset_trim_times", reset_trim)
