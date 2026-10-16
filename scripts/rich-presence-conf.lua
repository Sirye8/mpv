-- This file is part of mpv-rich-presence.
-- Copyright (c) 2026 Alden Wu.
-- Copyright (c) 2026 Youssef M. (Sirye8).
--
-- mpv-rich-presence is free software: you can redistribute it and/or modify it
-- under the terms of the GNU Affero General Public License as published by the
-- Free Software Foundation, either version 3 of the License, or (at your
-- option) any later version.
--
-- mpv-rich-presence is distributed in the hope that it will be useful, but
-- WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
-- FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
-- for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with mpv-rich-presence. If not, see <https://www.gnu.org/licenses/>.

local mp_msg = require("mp.msg")
local mp_options = require("mp.options")

local options = {
    application_id = "0",
    on = false,
    folder_filter_mode = "disabled",
    folder_list = "",
    pause_timeout = 1800,
}
mp_options.read_options(options, "rich-presence")

function pong()
    mp_msg.info("Ponging rich_presence with config data...")
    mp.commandv("script-message-to", "rich_presence", "application_id", options.application_id)

    if options.on then
        mp.commandv("script-message-to", "rich_presence", "on")
    else
        mp.commandv("script-message-to", "rich_presence", "off")
    end

    mp.commandv("script-message-to", "rich_presence", "folder_filter_mode", options.folder_filter_mode)
    mp.commandv("script-message-to", "rich_presence", "folder_list", options.folder_list)
    mp.commandv("script-message-to", "rich_presence", "pause_timeout", tostring(options.pause_timeout))
end

mp.register_script_message("ping", pong)
pong()
