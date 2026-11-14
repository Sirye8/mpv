-- SPDX-License-Identifier: AGPL-3.0-or-later
local help = {
    ["Now playing"]="See the current match, outgoing Discord card, and sharing status.",
    ["AniList"]="Connect an account, check list progress, and manage watch tracking.",
    ["Appearance"]="Preview the Discord card and save changes for a file, folder, or all media.",
    ["Recognition & folders"]="Choose a recognition source or correct a match for a file or folder.",
    ["Privacy & windows"]="Control sharing, lookups, tracking, and the active Discord window.",
    ["Saved data"]="Review saved settings, matches, cache entries, and local watch history.",
    ["Diagnostics"]="See the current provider, privacy rules, and recent Discord or AniList results.",
    ["View outgoing card"]="Open the read-only preview of the text, artwork and links Discord receives.",
    ["Preview"]="Open the read-only card preview with your current Appearance draft.",
    ["Correct match"]="Open recognition settings to change the source, title match or episode offset.",
    ["Correct episode"]="Enter the episode number used by the current AniList entry. This saves a correction for the current file only and leaves time already counted against the previous episode there. To change the series or season entry, use Correct match first.",
    ["Why this match?"]="See the chosen provider, the scope of the active recognition and match rules, and any reason AniList needs a review.",
    ["Local watch history"]="Review saved episode timers, list snapshots and pending changes on this device. Changing Discord visibility does not erase these records.",
    ["Retry search"]="Run this search again for the same file. A new search clears the previous result set so only results for this request can be selected.",
    ["Python helper"]="The local process that handles AniList sign-in, tracking, and supplemental metadata. If it exits, mpv retries with increasing delays. A new account or search action can retry after automatic recovery runs out.",
    ["Hide this file"]="Hide Discord for this file. The separate tracking permission still applies.",
    ["Share this file"]="Remove the temporary hide for this file.",
    ["Use this window for Discord"]="Make this window the active Discord publisher.",
    ["View AniList progress"]="Open the list entry for the current anime.",
    ["AniList progress"]="Open the list entry for the current anime.",
    ["Save for"]="Choose where this change is saved.",
    ["Media layout"]="Set the card for all media or just one media type.",
    ["Preset"]="Choose a starting layout. Selecting a preset resets all appearance overrides in the selected scope and media layout. Editing an appearance field marks it Custom and keeps the selected preset as its base.",
    ["Panel theme"]="Open the panel's own appearance settings. These apply immediately to this panel across mpv windows and do not change Discord cards.",
    ["Background color"]="Enter a six-digit RGB hex color such as #030405. This color tints the panel shell and is used to derive its row and hover colors.",
    ["Accent color"]="Enter a six-digit RGB hex color. It colors links, focus indicators, sliders and active controls. A light accent is easier to read on dark backgrounds.",
    ["Panel opacity"]="Enter 40 to 100 percent. Lower values let more video through. At 100 percent the panel shell is opaque. Dark glass defaults to 87 percent.",
    ["Blur strength"]="Enter 2 to 12 pixels. A larger value samples farther from each pixel, softening more of the background while the panel is open.",
    ["Restore panel theme defaults"]="Remove the saved theme and use Dark glass with the blur preference from rich-presence.conf.",
    ["Title language"]="Choose the anime title language. Missing translations fall back to the original title.",
    ["Episode numbering"]="Show the season-relative number, the original filename number, or both.",
    ["Timer"]="Choose how Discord shows time. AniList watch time uses a separate counter.",
    ["Release group"]="Show or hide the release group on the anime episode line.",
    ["Episode"]="Show or hide the anime episode number.",
    ["Artwork"]="Show available cover art or a poster from the matched source.",
    ["Badge"]="Show the small playback status icon.",
    ["Tooltip"]="Show playback status when someone hovers over the Discord badge.",
    ["Provider button"]="Show or hide the default link to the matched entry on its metadata provider.",
    ["Details"]="Show or hide the first text line under the activity name.",
    ["State"]="Show or hide the second text line under the activity name.",
    ["Compact status"]="Choose the card field Discord uses for compact status.",
    ["Episode titles"]="Show matched TV episode titles. Keep it off to avoid spoilers.",
    ["Headline"]="Set the activity name. Tokens include {title}, {artist}, {album}, {episode}, {original}, {group}, {channel}, {details}, {state}, and {year}.",
    ["Details template"]="Edit the first line using tokens such as {title} and {artist}. In {artist}|{title}, each piece is kept only if its tokens have values. Preview the result and choose Apply to save.",
    ["State template"]="Edit the second line using tokens such as {episode}, {album} and {year}. Separate optional pieces with |. A piece with a missing token is omitted. Preview the result and choose Apply to save.",
    ["Artwork link"]="Enter a public HTTP or HTTPS URL for the artwork, or clear the field to remove it.",
    ["Details link"]="Enter a public HTTP or HTTPS URL for the first text line, or clear the field to remove it.",
    ["State link"]="Enter a public HTTP or HTTPS URL for the second text line, or clear the field to remove it.",
    ["Edit public buttons"]="Enter Label|https://example.com. For two buttons, separate the entries with a comma. These replace the default provider button. Submit an empty value to hide all buttons.",
    ["Reset saved appearance"]="Clear the overrides at the chosen scope so it inherits its parent settings.",
    ["Apply"]="Save the preview to the selected scope.",
    ["Cancel"]="Discard the current action or unsaved preview.",
    ["Confirm"]="Apply the action described above to the selected scope.",
    ["Media recognition"]="Choose which providers can look up media for this scope. A file rule takes priority over the nearest folder rule, then the global panel rule, then the conf default. Choose Inherit to remove the current override.",
    ["TV folder rules"]="Off by default. When enabled, a TMDB TV or TVmaze search can save a series for matching titles in the exact folder. For example, a Loki rule can match Loki.S02E04 while Severance.S02E04 uses its own rule or Automatic. Bare episode numbers and conflicting titles use Automatic. Every file resolves its own episode. Rules are saved in Saved data and become inactive when this switch is off.",
    ["Local metadata files"]="Off by default. When enabled, a video can have a .mpv-rp.json file beside it, such as Loki.S02E04.mpv-rp.json next to Loki.S02E04.mkv. Set kind to movie or tv and tmdb to a numeric TMDB ID. For TV, season and episode are optional integers. The plugin fetches the referenced metadata only when lookups are allowed. Existing manual matches take precedence.",
    ["Measure unique footage"]="Off by default. Count the parts of an episode that actually played while this option was enabled. Replaying five minutes adds five minutes to elapsed watch time and only counts those five minutes once here. Seeks, pauses, and buffering add no coverage. The AniList threshold continues to use elapsed watch time. This setting follows Save for and Resume unfinished time.",
    ["Inherit recognition source"]="Remove this override and use the next applicable folder, global, or conf setting.",
    ["Automatic"]="Run the AniList anime matcher first for video. If it completes without a match, try movie or TV providers. For local audio, start with MusicBrainz tags and try AcoustID if the tags do not identify a match.",
    ["Anime"]="Use AniList's anime matcher only. If nothing matches, use the local title.",
    ["Movies & TV"]="Skip AniList. Episode markers select TV. Other titles try movies, then TV if no movie matches.",
    ["Movies"]="Skip AniList and TV. Use TMDB movies, with Wikidata as a fallback.",
    ["TV"]="Skip AniList and movies. Use TMDB TV, with TVmaze as a fallback. Dated episodes use TVmaze.",
    ["Original"]="Use AniList for anime and mpv's local title or tags for other media.",
    ["Local only"]="Use the filename, title or tags already available in mpv. An explicitly saved match still takes precedence.",
    ["Reset progress edit"]="Restore the episode count from the last list entry without saving a change to AniList.",
    ["No saved records"]="This category has no saved records for the current profile or account.",
    ["No matching records"]="Clear or change the search to see other records in this category.",
    ["TMDB movies"]="Match movies and posters with the shared TMDB service or your own token.",
    ["TMDB TV"]="Match TV series and episodes with the shared TMDB service or your own token.",
    ["TVmaze"]="Match TV shows and find episodes by season and number or air date.",
    ["Wikidata"]="Match film titles and release years using public Wikidata records.",
    ["MusicBrainz"]="Match music by its tags and fetch artwork for an identified release.",
    ["Stream metadata"]="Use the media title and channel reported by mpv.",
    ["AcoustID"]="Match local audio by fingerprint. The package includes fpcalc and the application key.",
    ["Provider settings and credits"]="See provider requirements and which optional keys are configured.",
    ["AniList search"]="Search anime titles by name and choose a match.",
    ["Enter AniList ID or URL"]="Enter a positive AniList ID or an anilist.co/anime URL.",
    ["Episode offset"]="Adjust the episode number used for matching and AniList progress. For example, enter -12 when the filename says episode 13 and this season starts at episode 1. Enter 0 for the normal mapping.",
    ["Mark as non-anime"]="Skip AniList matching for this file or folder.",
    ["Refresh match"]="Run recognition again while keeping saved corrections.",
    ["Discord"]="Choose what this scope shares.",
    ["Start private session"]="Stop Discord sharing, lookups, and tracking for this session.",
    ["End private session"]="Restore the usual file and folder privacy rules.",
    ["Exclude this folder"]="Review blocking Discord, recognition, and tracking in this folder and its subfolders.",
    ["Hide Discord for a time"]="Enter a whole number from 1 to 1440 minutes. Enter 0 to end the timed hide.",
    ["Hide Discord until this window closes"]="Hide this window's Discord presence until it closes.",
    ["End window hide"]="Restore the usual sharing rules for this window.",
    ["Pin this window for Discord"]="Keep this eligible window as the Discord publisher.",
    ["Return to last-resumed window"]="Release the pin so the last resumed eligible window can publish.",
    ["Use this window"]="Make this window the active Discord publisher.",
    ["Track while hidden"]="Allow tracking while Discord is hidden. Private sessions and exclusions still block it.",
    ["Connect account"]="Approve sign-in in your browser and use the OS credential store when available.",
    ["Connect for this session"]="Approve sign-in in your browser and keep the credential in memory until mpv closes.",
    ["Reconnect to AniList"]="Renew the expired AniList session through the browser.",
    ["Switch or reconnect account"]="Open browser sign-in again. Switch accounts in your browser first if needed.",
    ["Refresh list entry"]="Read the current episode count and status from AniList.",
    ["Disconnect"]="Choose whether to keep or forget this account's local watch history.",
    ["Keep local watch history"]="Disconnect and cancel pending updates. Keep local counters and history.",
    ["Forget local watch history"]="Disconnect and clear this account's local tracking records and cached entries.",
    ["−  One episode"]="Decrease the draft by one, down to zero.",
    ["+  One episode"]="Increase the draft by one, up to the known episode total.",
    ["Episodes watched"]="Adjust the total number of watched episodes with minus, plus, Left or Right. This edit stays in the panel until you confirm Apply progress.",
    ["Status on Apply"]="Keep the current list status or choose a different status for this edit.",
    ["Apply progress"]="Review the progress and status change before sending it to AniList.",
    ["Reset draft"]="Restore the saved episode count in the draft.",
    ["Mark current episode watched"]="Review setting your progress to the episode playing now.",
    ["Tracking"]="Choose whether to count watch time and how to send progress to AniList.",
    ["Before leaving position"]="Move the popup shown before leaving. This setting also applies to Auto reviews.",
    ["Episode type"]="The matched file needs a decision before it can count as a whole episode. Auto shows a review before leaving.",
    ["Pending updates"]="Open saved progress proposals for episodes that reached the threshold. Play the matching episode to review and apply a proposal. Offline proposals need a fresh AniList read first. Skip suppresses the proposal for that episode in this viewing cycle.",
    ["Start new viewing cycle"]="Start fresh local watch counters for the matched AniList entry and clear its pending updates. Earlier viewing cycles remain in Saved data.",
    ["Threshold"]="Set how many real minutes to watch each episode before Ask or Auto can act. Enter a whole number from 1 to 1440. The default is 15. At 2× speed, one real minute still counts as one minute.",
    ["Ask prompt timeout"]="Choose Never, a preset, or 5 to 300 seconds. When a timed prompt expires, mpv continues and keeps the proposal in Pending updates.",
    ["Custom timeout"]="Enter a whole number from 5 to 300 seconds. For an untimed prompt, choose Never.",
    ["Later"]="Keep the proposal pending and return to the previous page.",
    ["Skip this episode"]="Dismiss the proposal and suppress automatic credit for the episode.",
    ["Update and switch to Watching"]="Review the episode progress and change the entry to Watching.",
    ["Add to Watching and update"]="Review adding this anime to Watching with the proposed progress.",
    ["Update progress only"]="Review the new progress. Automatic mode keeps this list status for later updates until the status changes.",
    ["Resume rewatch and update"]="Review returning this entry to Rewatching with the proposed progress.",
    ["Finish rewatch"]="Review completing the rewatch and recording it in your rewatch count.",
    ["Record completed rewatch"]="Review recording another complete viewing of this one-episode anime.",
    ["Filter records"]="Search within this category by record label or key. This only changes the list on screen.",
    ["Clear search"]="Show every record in this category again.",
    ["Saved profiles"]="Browse saved appearance, privacy, recognition, tracking and folder preferences by type.",
    ["Saved matches"]="Review manual title matches and episode corrections saved for a file or folder.",
    ["Saved caches"]="Browse temporary metadata responses and clear them to refresh provider lookups.",
    ["Saved AniList data"]="Browse this account's local watch timers, pending proposals, skips, completed updates and cached list entries.",
    ["Folder filters"]="Review the whitelist or blacklist, edit the folder list, or temporarily allow playback in this window.",
    ["Filter source"]="Shows whether both settings come from rich-presence.conf or at least one is overridden in the panel.",
    ["Current folder access"]="Shows whether the configured folder filter allows this file. Private sessions and exclusions are checked separately.",
    ["Current folder"]="Directory containing the open local file. Use Add current folder to save it in the filter list.",
    ["Allow this file until it closes"]="Bypass the folder filter for the open file only. Discord and metadata become eligible if other sharing and privacy settings allow them.",
    ["Bypass the filter in this window"]="Temporarily bypass the whitelist or blacklist for local files in this window. Exclusions and private mode still apply. Other windows keep the saved filter.",
    ["End temporary exception"]="Restore the saved filter for this window immediately.",
    ["Add current folder"]="Save the open file's directory and its subfolders in the list. A whitelist allows listed folders. A blacklist blocks them.",
    ["Listed folders"]="Open the list of folders used by the whitelist or blacklist. Select a folder to review removing it.",
    ["Add folder path"]="Enter an absolute directory path. The rule also applies to files in subfolders.",
    ["Restore conf filter"]="Remove the panel's filter mode and folder list overrides, then use both values from rich-presence.conf.",
    ["Reset everything"]="Clear local settings, saved matches, caches and watch history. Disconnect AniList and restore the defaults from rich-presence.conf. This leaves your remote AniList list as it is.",
    ["Fingerprint this file"]="Analyze up to the first two minutes of the local audio and look up the resulting fingerprint on AcoustID. Review the results before saving a match. The package supplies fpcalc and the application key.",
    ["Sharing"]="Why this window is sharing or hidden.",
    ["SDK"]="Latest result from the Discord SDK.",
    ["Configuration"]="Whether the plugin received its configuration from Lua.",
    ["Publisher"]="Which mpv window currently owns the Discord card.",
    ["Lookup"]="Whether the active privacy rules permit recognition requests.",
    ["Recognition status"]="Shows whether recognition is still searching, found a match, fell back to local metadata, or ended because a provider was unavailable.",
    ["Recognition source"]="Provider supplying the metadata for this file.",
    ["Source rule"]="Scope of the active recognition setting.",
    ["Match rule"]="Scope of the active match correction.",
    ["Appearance rule"]="Scope of the active card settings.",
    ["Last list read"]="Time of the latest successful AniList read.",
    ["Last list write"]="Time of the latest confirmed AniList update.",
    ["AniList ID"]="Matched anime entry ID. Zero means there is no AniList match.",
    ["Account operation"]="Latest message from the account or recognition helper.",
}

local choices = {
    ["Panel theme preset"]={
        glass="Dark glass. Near-black, 87 percent opacity, with a soft live blur.",
        midnight="Midnight. Deep blue with more visible video and a stronger blur.",
        graphite="Graphite. An opaque charcoal panel with blur disabled.",
        custom="Custom. Keep the current colors, opacity and blur settings. Editing any theme field also selects this preset.",
    },
    ["Background blur"]={
        On="Apply live blur beneath this panel on mpv's gpu-next video output. Other outputs keep translucency.",
        Off="Show the video through the translucent panel without filtering the background.",
    },
    ["Release idle Discord pin"]={
        On="Release this window's exclusive Discord pin when sharing is blocked, playback ends, or its pause timeout expires. Another eligible mpv window can claim Discord. Pin this window again to restore exclusive ownership.",
        Off="Keep the pin for this window until you unpin it, close the window, or its lease expires. This is the default."},
    ["Ask before fingerprinting"]={
        On="If MusicBrainz cannot identify a local track, show Fingerprint this file in Now playing. Choosing it sends an audio fingerprint and duration to AcoustID. The audio file stays on this device.",
        Off="Keep the default fallback. Automatic can look up a fingerprint when local tags and MusicBrainz cannot identify the track."},
    ["TV folder rules"]={
        On="Offer conditional series rules in TV search results. A rule needs a matching series title and an episode or date. Each file gets its own episode metadata.",
        Off="Ignore saved folder series rules. File-specific corrections and the selected recognition source still apply."},
    ["Local metadata files"]={
        On="Read a matching .mpv-rp.json file beside the video when supplemental recognition runs. Use a TMDB movie or TV ID and optional TV season and episode.",
        Off="Use normal recognition and saved manual matches. Local metadata files are ignored."},
    ["Measure unique footage"]={
        On="Count each part of the episode once while this is enabled. The watch timer and AniList threshold still count real playback time.",
        Off="Stop recording unique coverage. Watch time and AniList progress follow your tracking mode."},
    ["Filter mode"]={disabled="Ignore the folder list.",whitelist="Allow only listed folders and their subfolders. An empty whitelist blocks every file.",blacklist="Block listed folders and their subfolders. An empty blacklist blocks no files."},
    ["Save for"]={global="Apply to all media.",folder="Apply to this folder and its subfolders.",file="Apply only to the current file."},
    ["Media layout"]={all="Every media type.",anime="Matched anime.",audio="Unmatched audio.",video="Unmatched video.",
        movie="Matched movies.",tv="Matched TV episodes or shows.",recording="Matched music.",stream="Matched streams."},
    ["Preset"]={original="Use the standard Rich Presence layout.",clean="Keep the card compact and omit the release group.",
        detailed="Include more context where available.",private="Use a generic card."},
    ["Title language"]={original="Use the original match title.",english="Prefer the English title.",
        romaji="Prefer the Romanized title.",native="Prefer the native-script title."},
    ["Episode numbering"]={relative="Use the matched season’s numbering.",original="Use the number from the filename.",
        both="Show both when they differ."},
    ["Timer"]={progress="Show playback progress.",remaining="Show the time left.",session="Show time since the file opened.",
        off="Hide the Discord timer."},
    ["Compact status"]={name="Use the activity name.",details="Use the first text line.",state="Use the second text line."},
    ["Discord"]={full="Share the full card.",generic="Share a plain card without the media details.",
        hidden="Hide this activity on Discord."},
    ["Status on Apply"]={unchanged="Keep the saved status.",CURRENT="Mark as watching.",COMPLETED="Mark as completed.",
        REPEATING="Mark as rewatching.",PAUSED="Mark as paused.",DROPPED="Mark as dropped.",PLANNING="Mark as planned."},
    ["Tracking"]={off="Stop counting watch time. Saved time stays available.",
        manual="Count real playback time. Use the AniList panel to apply list changes yourself.",
        ask="Count time and open a progress review according to Ask timing once the threshold is reached.",
        auto="Advance confirmed consecutive episodes at the threshold. Gaps, new entries, status changes, and extras such as recaps or fractional episodes open a review before leaving."},
    ["Ask timing"]={
        threshold="Show the popup as soon as the watch threshold is reached and the proposal is ready. Playback continues.",
        ["end"]="Show the ready proposal when the episode reaches its end. Hold automatic playlist advance while you decide.",
        leave="Review before a standard quit or playlist key, window close, or automatic playlist advance. The rest of mpv stays usable during review."},
    ["Ask prompt position"]={
        ["top-right"]="Upper right, the default.",["top-center"]="Centered at the top.",["top-left"]="Upper left.",
        ["bottom-right"]="Lower right above playback controls.",["bottom-center"]="Centered above playback controls.",
        ["bottom-left"]="Lower left above playback controls."},
    ["Panel position"]={config="Use the position in rich-presence.conf.",
        ["top-left"]="Upper left, the default.",["top-center"]="Centered at the top.",["top-right"]="Upper right.",
        ["bottom-left"]="Lower left above playback controls.",["bottom-center"]="Centered above playback controls.",
        ["bottom-right"]="Lower right above playback controls."},
    ["Track while hidden"]={
        On="Keep counting eligible playback when Discord sharing is hidden. Private sessions and excluded folders still block tracking.",
        Off="Count watch time only while sharing is permitted for the file."},
    ["Resume unfinished time"]={
        On="Carry over saved time for the same AniList account, episode, and viewing cycle when you reopen the file. For example, 6 minutes now and 9 later reach a 15-minute threshold.",
        Off="Start a fresh counter when you reopen the episode or another mpv window takes over. Pausing or seeking in the same session keeps the time already counted."},
    ["Keep offline proposals"]={
        On="If Ask or Auto reaches the threshold while AniList is unavailable, save a local pending item. It needs a fresh list check before it can be applied.",
        Off="Keep counting watch time while offline. Ask or Auto waits for a successful AniList read before creating the proposal."},
    ["Rewatch tracking"]={
        On="In Ask or Auto, reaching the threshold on episode 1 of a Completed anime offers to start a new rewatch. Approving sets Rewatching and records episode 1 in a separate cycle. Recording the known final episode adds one to the repeat count.",
        Off="Skip the offer to start a new rewatch from Completed. Entries already marked Rewatching follow the selected Tracking mode."},
    ["Release group"]={On="Show the release group on the episode line.",Off="Hide the release group."},
    Episode={On="Show the anime episode number.",Off="Hide the episode number."},
    Artwork={On="Show available cover art.",Off="Hide the large artwork."},
    Badge={On="Show the playback status icon.",Off="Hide the status icon."},
    Tooltip={On="Show status when hovering over the badge.",Off="Hide the badge’s hover text."},
    ["Provider button"]={On="Show the default provider link.",Off="Hide the default provider link."},
    Details={On="Show the first text line.",Off="Hide the first text line."},
    State={On="Show the second text line.",Off="Hide the second text line."},
    ["Episode titles"]={On="Show matched TV episode titles.",Off="Hide episode titles to avoid spoilers."},
}

local read_only = {
    ["Card preview"]={
        Activity="Activity type and name that Discord receives.",
        Details="First text line under the activity name. Change it in Appearance.",
        State="Second text line under the activity name. Change it in Appearance.",
        Artwork="Image URL for the large artwork on the card.",
        ["Artwork tooltip"]="Text Discord shows when someone hovers over the large artwork.",
        Badge="Image URL for the small playback status badge.",
        ["Badge tooltip"]="Text Discord shows when someone hovers over the badge.",
        ["Compact status"]="Field selected for Discord’s compact status.",
        ["Artwork link"]="Public link attached to the large artwork.",
        ["Details link"]="Public link attached to the first text line.",
        ["State link"]="Public link attached to the second text line.",
        ["Public button"]="This label and URL are sent to Discord. The button can be changed in Appearance.",
    },
    ["Now playing"]={Sharing="Current Discord sharing status.",Activity="Activity type and name on the current card.",
        Details="First text line on the current Discord card.",State="Second text line on the current Discord card."},
    ["AniList"]={Account="Account connected in mpv.",Anime="Title of the matched anime.",
        ["Playing episode"]="Season-relative episode number used for AniList.",
        ["Episode watch time"]="Real playback time for this episode and viewing cycle. Pauses, buffering, and seeks add no time. At 2×, a real minute still adds one minute.",
        ["Watch started"]="Local clock time of the first credited playback interval in this viewing cycle. Older records may only have elapsed time.",
        ["Last watched"]="Local clock time of the latest credited playback interval in this viewing cycle.",
        ["List entry"]="Most recently confirmed AniList progress and status for this anime.",
        ["List status"]="Whether mpv has a current AniList entry for this anime."},
    ["Recognition & folders"]={["Source rule"]="Scope that supplied the active recognition choice.",
        ["Open a local file to set its folder source"]="A local file must be open before you can assign a folder rule."},
    Providers={AniList="Public anime metadata and artwork. Signing in is only needed for list features.",
        TMDB="Movie and TV metadata uses the shared service or the optional tmdb_key in rich-presence.conf.",
        TVmaze="TV metadata and aired episode order. Data is licensed under CC BY-SA.",
        Wikidata="Public film titles and release dates.",MusicBrainz="Public music recording and release data.",
        ["Cover Art Archive"]="Artwork for matched MusicBrainz releases.",
        ["TMDB attribution"]="TMDB supplies the metadata and posters used by this project."},
    ["Saved match"]={Scope="File, folder or global scope of this saved correction."},
    ["Disconnect account"]={Account="The account that the selected action will disconnect from mpv."},
    ["Pending updates"]={Proposal="Anime and episode covered by this local proposal.",
        ["Waiting to refresh remote progress"]="Refresh the AniList entry before applying this proposal.",
        ["Play this episode to apply its update"]="Open the matching episode so mpv can verify the proposal’s playback context.",
        ["No pending updates"]="There are no saved proposals for the connected account."},
    ["Search results"]={["Searching…"]="Waiting for the selected provider to return matches.",
        ["No results"]="The provider returned no matches for this search."},
}

return function(label, page, action, values, current, key)
    key=key or label:match("^(.-)   ") or label
    if values then
        local descriptions=key=="Before leaving position" and choices["Ask prompt position"] or choices[key]
        local names=key=="Ask timing" and {threshold="At threshold",["end"]="End of episode",leave="Before leaving"} or {}
        local options={}
        for _,value in ipairs(values) do
            options[#options+1]={label=names[value] or value,selected=value==current,
                detail=(key=="Before leaving position" and value=="center" and "Center of the playback area. This is the default for Before leaving and Auto reviews.") or descriptions and descriptions[value] or
                    (value=="On" and (help[key] or "Enable this setting.") or "Leave this off.")}
        end
        return {options=options}
    end
    if not page then return help[key] end
    if not action then
        local fields=read_only[page] or {}
        local description=fields[key]
        if key=="Message" then description="Latest status message from mpv or the account helper."
        elseif page=="Folder filters" then description=help[key]
        elseif page:match("^Saved") then description=key=="Scope" and "Where this saved rule applies." or help[key]
        elseif page=="Card preview" and key:match("^Public button %d+$") then description=fields["Public button"]
        elseif page=="Pending updates" and key:match("^Proposal ") then description=fields.Proposal
        elseif page=="Diagnostics" then description=help[key]
        elseif page=="Confirm" then description="Review the proposed action before you confirm."
        elseif page=="Providers" then description=description or "Provider attribution or setup information." end
        local value=label:match("^.-   (.+)$")
        if page=="AniList" and key=="Episode watch time" and value then
            if value:match("^Tracking is off") then
                description="Set Tracking to Manual, Ask, or Auto to start counting. Manual counts time and lets you apply any AniList progress changes yourself."
            elseif value=="Tracking blocked" then
                description="Current sharing or privacy settings prevent tracking. Track while hidden can allow tracking when Discord is hidden. Private sessions and excluded folders block it."
            elseif value=="No time recorded yet" then
                description="Play the matched episode for a few seconds to start counting. Pauses, buffering, and seeks suspend the counter."
            elseif value=="Episode needs review" then
                description="The counter needs one confirmed whole episode. Auto shows a review for detected fractional episodes, recaps, and specials before leaving. Use Correct match if the title or numbering is uncertain."
            end
        end
        if page=="AniList" and (key=="Watch started" or key=="Last watched") and value then
            description=value..". "..description
        end
        return "Read only. "..(description or "Information for this page.")
    end
    if page=="Saved match" then return "Review removing this field from the saved correction. Other fields stay saved." end
    if page=="Search results" then return "Review saving this provider match at the selected scope." end
    if key:match("^Clear ") then return "Review which local records in this category will be removed." end
    if page=="Saved data" and not help[key] then return "Open this local record or review removing it at the displayed scope." end
    if key:match("^Search ") then return "Enter a title to find matches from this provider." end
    if key:match("^Start rewatch and record episode ") then return "Review resetting progress to episode 1 and switching the entry to Rewatching." end
    if key:match("^Update episode ") or key:match("^Apply ") then return "Review the proposed change before sending it to AniList." end
    if key:match("^Skip ") then return "Dismiss the proposal and suppress automatic updates for this episode." end
    return help[key] or "Select to continue."
end
