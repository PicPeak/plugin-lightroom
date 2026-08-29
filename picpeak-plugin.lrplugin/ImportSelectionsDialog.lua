--[[
    "Import selections from PicPeak" — event picker, RAW folder picker, and
    the scope/merge controls (PicPeak/picpeak#745).

    The default is deliberately the safe one at every choice: import all
    photos rather than a filtered subset the user did not ask for, never
    overwrite a label already in the catalog, and leave the weaker
    number-matching off.
]]

require("PicPeakAPI")
require("ColorLabelMerge")
require("ImportSelectionsTask")
require("TokenStore")

ImportSelectionsDialog = {}

local COLORS = { "green", "yellow", "red", "blue", "purple" }

local SCOPES = {
    { title = "All photos in the event", value = "all" },
    { title = "Only photos that were marked", value = "marked" },
    { title = "Only specific colours / ratings", value = "specific" },
}

local MARK_SOURCES = {
    { title = "Client picks and my own marks", value = "either" },
    { title = "Client picks only", value = "client" },
    { title = "My own marks only", value = "mine" },
}

--[[
    Remember the dialog's settings between runs.

    Lightroom gives a plugin no persistent panel — this is a menu item, so the
    dialog is rebuilt from scratch every time it is opened. Re-typing the RAW
    folder and re-picking the scope on every import is the single most tedious
    part of the workflow, so the answers are kept in prefs.

    Stored as individual keys rather than one table: LrPrefs round-trips
    scalars reliably, and a single malformed table would lose every setting at
    once instead of one.
]]
local PERSISTED = {
    "eventId", "folderPath", "recurse", "scope", "markSource", "minRating",
    "applyColors", "applyRatings", "mergeMode", "addMissingToCatalog",
    "allowNumberMatch", "collectionName",
}

local function restoreSettings(props)
    for _, key in ipairs(PERSISTED) do
        local stored = _G.prefs["import_" .. key]
        if stored ~= nil then
            props[key] = stored
        end
    end
    for _, color in ipairs(COLORS) do
        local stored = _G.prefs["import_color_" .. color]
        if stored ~= nil then
            props["color_" .. color] = stored
        end
    end
end

local function saveSettings(props)
    for _, key in ipairs(PERSISTED) do
        _G.prefs["import_" .. key] = props[key]
    end
    for _, color in ipairs(COLORS) do
        _G.prefs["import_color_" .. color] = props["color_" .. color]
    end
end

local function selectedColors(props)
    local picked = {}
    for _, color in ipairs(COLORS) do
        if props["color_" .. color] then
            table.insert(picked, color)
        end
    end
    return table.concat(picked, ",")
end

-- Turn the dialog state into getEventPhotos filters.
local function buildFilters(props)
    local filters = { markSource = props.markSource }

    if props.scope == "marked" then
        filters.markedOnly = true
        return filters
    end
    if props.scope ~= "specific" then
        return filters
    end

    local colors = selectedColors(props)
    if colors ~= "" then
        -- Which side the colours apply to follows the mark source, so
        -- "my own marks only" + green does not quietly filter on the
        -- client's greens instead.
        if props.markSource == "mine" then
            filters.myColorLabels = colors
        else
            filters.colorLabels = colors
        end
    end
    if props.minRating and props.minRating > 0 then
        if props.markSource == "mine" then
            filters.myMinRating = props.minRating
        else
            filters.minRating = props.minRating
        end
    end
    -- OR, so "green OR 3 stars" reads the way the checkboxes look. AND would
    -- silently return nothing for the common case of picking both.
    filters.logic = "OR"
    return filters
end

local function summaryMessage(summary)
    local lines = {}
    table.insert(lines, string.format("%d photo(s) fetched from PicPeak.", summary.fetched or 0))
    table.insert(lines, string.format("%d matched a local file, %d had no match.",
        summary.matched or 0, #(summary.unmatched or {})))
    table.insert(lines, string.format("%d added to the catalog, %d were already in it.",
        summary.imported or 0, summary.alreadyInCatalog or 0))
    table.insert(lines, string.format("%d colour label(s) and %d rating(s) written.",
        summary.colorsWritten or 0, summary.ratingsWritten or 0))
    if (summary.conflicts or 0) > 0 then
        table.insert(lines, string.format(
            "%d photo(s) already had a different value and were left as-is or "
            .. "overwritten according to your conflict setting.", summary.conflicts))
    end
    if summary.collectionName then
        table.insert(lines, "Collection: " .. summary.collectionName)
    end
    if summary.errors and #summary.errors > 0 then
        table.insert(lines, "")
        table.insert(lines, string.format("%d problem(s):", #summary.errors))
        for i, err in ipairs(summary.errors) do
            if i > 5 then
                table.insert(lines, string.format("  ... and %d more (see the log).", #summary.errors - 5))
                break
            end
            table.insert(lines, "  " .. tostring(err.name) .. ": " .. tostring(err.reason))
        end
    end
    if summary.unmatched and #summary.unmatched > 0 then
        table.insert(lines, "")
        table.insert(lines, "Unmatched (first few):")
        for i, miss in ipairs(summary.unmatched) do
            if i > 5 then
                table.insert(lines, string.format("  ... and %d more.", #summary.unmatched - 5))
                break
            end
            table.insert(lines, "  " .. tostring(miss.name) .. " — " .. tostring(miss.reason))
        end
    end
    return table.concat(lines, "\n")
end

--[[
    Show the importer.

    @return "connection" when the user asked for the connection screen, so the
            caller can show it and call back in. Returned rather than opened
            here: nesting modal dialogs is where Lightroom plugins deadlock, so
            this window closes first and the caller reopens it afterwards.
]]
function ImportSelectionsDialog.show()
    local prefs = _G.prefs
    local apiToken = TokenStore.get(prefs.url)
    if util.nilOrEmpty(prefs.url) or util.nilOrEmpty(apiToken) then
        -- Send them straight to the fix rather than describing where it lives.
        return "connection"
    end

    local api = PicPeakAPI:new(prefs.url, apiToken)
    local events = api:getEvents(100)
    if not events or #events == 0 then
        local choice = LrDialogs.confirm(
            "No events found",
            "PicPeak returned no galleries for this account — the server may be "
                .. "unreachable, or the token may have been revoked.",
            "Check connection",
            "Cancel"
        )
        return choice == "ok" and "connection" or nil
    end

    local outcome = nil
    LrFunctionContext.callWithContext("picpeakImportSelections", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        props.eventId = events[1].value
        props.folderPath = ""
        props.recurse = true
        props.scope = "all"
        props.markSource = "either"
        props.minRating = 0
        props.applyColors = true
        props.applyRatings = true
        props.mergeMode = "fill_empty"
        props.addMissingToCatalog = true
        props.allowNumberMatch = false
        props.collectionName = "PicPeak selections"
        for _, color in ipairs(COLORS) do
            props["color_" .. color] = false
        end
        -- Defaults first, then whatever the last run used.
        restoreSettings(props)

        local lw = LrView.share("importLabel")
        local colorRow = { spacing = f:label_spacing() }
        for _, color in ipairs(COLORS) do
            table.insert(colorRow, f:checkbox({
                title = color:sub(1, 1):upper() .. color:sub(2),
                value = LrView.bind("color_" .. color),
                enabled = LrView.bind({
                    key = "scope",
                    transform = function(value) return value == "specific" end,
                }),
            }))
        end

        local signedIn = util.nilOrEmpty(prefs.signedInAs)
            and "Connected with a manually entered API token."
            or ("Signed in as " .. tostring(prefs.signedInAs))

        local contents = f:column({
            spacing = f:control_spacing(),
            bind_to_object = props,

            f:static_text({
                title = tostring(prefs.url) .. "  —  " .. signedIn,
                font = "<system/small>",
                fill_horizontal = 1,
                truncation = "middle",
            }),
            f:separator({ fill_horizontal = 1 }),

            f:row({
                f:static_text({ title = "Event:", alignment = "right", width = lw }),
                f:popup_menu({ items = events, value = LrView.bind("eventId"), fill_horizontal = 1 }),
            }),

            f:row({
                f:static_text({ title = "RAW folder:", alignment = "right", width = lw }),
                f:edit_field({ value = LrView.bind("folderPath"), fill_horizontal = 1, truncation = "middle" }),
                f:push_button({
                    title = "Choose…",
                    action = function()
                        local chosen = LrDialogs.runOpenPanel({
                            title = "Choose the folder holding the RAW files",
                            canChooseFiles = false,
                            canChooseDirectories = true,
                            allowsMultipleSelection = false,
                        })
                        if chosen and chosen[1] then
                            props.folderPath = chosen[1]
                        end
                    end,
                }),
            }),
            f:row({
                f:static_text({ title = "", width = lw }),
                f:checkbox({ title = "Include subfolders", value = LrView.bind("recurse") }),
            }),

            f:separator({ fill_horizontal = 1 }),

            f:row({
                f:static_text({ title = "Import:", alignment = "right", width = lw }),
                f:popup_menu({ items = SCOPES, value = LrView.bind("scope"), fill_horizontal = 1 }),
            }),
            f:row({
                f:static_text({ title = "Marks from:", alignment = "right", width = lw }),
                f:popup_menu({ items = MARK_SOURCES, value = LrView.bind("markSource"), fill_horizontal = 1 }),
            }),
            f:row({
                f:static_text({ title = "Colours:", alignment = "right", width = lw }),
                f:row(colorRow),
            }),
            f:row({
                f:static_text({ title = "Minimum stars:", alignment = "right", width = lw }),
                f:popup_menu({
                    items = {
                        { title = "Any", value = 0 }, { title = "1+", value = 1 },
                        { title = "2+", value = 2 }, { title = "3+", value = 3 },
                        { title = "4+", value = 4 }, { title = "5", value = 5 },
                    },
                    value = LrView.bind("minRating"),
                    enabled = LrView.bind({
                        key = "scope",
                        transform = function(value) return value == "specific" end,
                    }),
                }),
            }),

            f:separator({ fill_horizontal = 1 }),

            f:row({
                f:static_text({ title = "Apply:", alignment = "right", width = lw }),
                f:checkbox({ title = "Colour labels", value = LrView.bind("applyColors") }),
                f:checkbox({ title = "Star ratings", value = LrView.bind("applyRatings") }),
            }),
            f:row({
                f:static_text({ title = "If it differs:", alignment = "right", width = lw }),
                f:popup_menu({
                    items = ColorLabelMerge.MODES,
                    value = LrView.bind("mergeMode"),
                    fill_horizontal = 1,
                }),
            }),
            f:row({
                f:static_text({ title = "", width = lw }),
                f:static_text({
                    title = "Only applies when the photo already carries a different "
                        .. "label or rating in Lightroom.",
                    font = "<system/small>",
                    fill_horizontal = 1,
                }),
            }),

            f:separator({ fill_horizontal = 1 }),

            f:row({
                f:static_text({ title = "", width = lw }),
                f:checkbox({
                    title = "Add matching files that aren't in the catalog yet",
                    value = LrView.bind("addMissingToCatalog"),
                }),
            }),
            f:row({
                f:static_text({ title = "", width = lw }),
                f:checkbox({
                    title = "Also match by trailing file number",
                    value = LrView.bind("allowNumberMatch"),
                }),
            }),
            f:row({
                f:static_text({ title = "", width = lw }),
                f:static_text({
                    title = "Weaker than matching the full name — use it when the RAWs "
                        .. "were renamed. Files sharing a number are skipped, never guessed.",
                    font = "<system/small>",
                    fill_horizontal = 1,
                }),
            }),
            f:row({
                f:static_text({ title = "Collection:", alignment = "right", width = lw }),
                f:edit_field({ value = LrView.bind("collectionName"), fill_horizontal = 1 }),
            }),
        })

        local result = LrDialogs.presentModalDialog({
            otherVerb = "Connection…",
            title = "Import selections from PicPeak",
            contents = contents,
            actionVerb = "Import",
        })
        if result == "other" then
            outcome = "connection"
            return
        end
        if result ~= "ok" then
            return
        end
        saveSettings(props)

        if util.nilOrEmpty(props.folderPath) then
            LrDialogs.message("Choose a RAW folder", "Pick the folder that holds the RAW files first.", "warning")
            return
        end
        if not LrFileUtils.exists(props.folderPath) then
            LrDialogs.message("Folder not found", tostring(props.folderPath) .. " does not exist.", "critical")
            return
        end
        if not props.applyColors and not props.applyRatings then
            LrDialogs.message(
                "Nothing to apply",
                "Tick colour labels, star ratings, or both.",
                "warning"
            )
            return
        end

        local eventName = ""
        for _, event in ipairs(events) do
            if event.value == props.eventId then
                eventName = event.title
            end
        end

        LrFunctionContext.callWithContext("picpeakImportSelectionsRun", function(runContext)
            local progress = LrProgressScope({
                title = "Importing PicPeak selections",
                functionContext = runContext,
            })
            progress:setCancelable(true)

            local summary = ImportSelectionsTask.run({
                api = api,
                eventId = props.eventId,
                eventName = eventName,
                folderPath = props.folderPath,
                recurse = props.recurse,
                allowNumberMatch = props.allowNumberMatch,
                applyColors = props.applyColors,
                applyRatings = props.applyRatings,
                mergeMode = props.mergeMode,
                addMissingToCatalog = props.addMissingToCatalog,
                collectionName = props.collectionName,
                filters = buildFilters(props),
            }, progress)

            progress:done()

            if summary.fatal then
                LrDialogs.message("Import failed", summary.fatal, "critical")
            elseif summary.canceled then
                LrDialogs.message("Import canceled", "No changes were applied.", "info")
            else
                LrDialogs.message("PicPeak selections imported", summaryMessage(summary), "info")
            end
        end)
    end)
    return outcome
end

return ImportSelectionsDialog
