--[[
    The PicPeak overview — the plugin's landing page.

    Shows which server is connected, lets the user switch between servers when
    more than one is known, and offers the actions at the bottom.

    Two constraints shape the layout:

    * `presentModalDialog` gives exactly three buttons (action / other /
      cancel). "Open web interface" is therefore a push_button in the BODY —
      which is fine precisely because it opens a browser rather than another
      dialog. Anything that opens a dialog has to be one of the three verbs, so
      the window can close first.
    * Never nest modal dialogs. Config and Import are returned to the caller as
      a string; the caller closes this window, runs that flow, and reopens.
]]

require("ServerStore")
require("TokenStore")

PicPeakOverview = {}

local function connectionSummary(url)
    if util.nilOrEmpty(url) then
        return "No server configured yet — start with Config."
    end
    if util.nilOrEmpty(TokenStore.get(url)) then
        return "Not signed in to this server."
    end
    if not util.nilOrEmpty(_G.prefs.signedInAs) then
        local expiry = _G.prefs.tokenExpiresAt
        if not util.nilOrEmpty(expiry) then
            return "Signed in as " .. tostring(_G.prefs.signedInAs)
                .. " — token expires " .. string.sub(tostring(expiry), 1, 10)
        end
        return "Signed in as " .. tostring(_G.prefs.signedInAs)
    end
    return "Connected with a manually entered API token."
end

--[[
    @return "import" | "config" | nil (closed)
]]
function PicPeakOverview.show()
    local outcome = nil

    LrFunctionContext.callWithContext("picpeakOverview", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        local servers = ServerStore.menuItems()
        props.serverUrl = ServerStore.getActive()
        props.status = connectionSummary(props.serverUrl)

        -- Switching server switches the credential too: TokenStore is keyed by
        -- URL, so the picker is the whole of "use my other PicPeak".
        props:addObserver("serverUrl", function(p)
            ServerStore.setActive(p.serverUrl)
            p.status = connectionSummary(p.serverUrl)
        end)

        local rows = {
            spacing = f:control_spacing(),
            bind_to_object = props,

            f:static_text({ title = "PicPeak", font = "<system/bold>" }),
            f:static_text({
                title = "Round-trip your client's proofing selections.",
                font = "<system/small>",
            }),
            f:separator({ fill_horizontal = 1 }),
        }

        -- The picker only earns its space once there is a choice to make.
        if #servers > 1 then
            table.insert(rows, f:row({
                f:static_text({ title = "Server:", alignment = "right",
                                width = LrView.share("ovLabel") }),
                f:popup_menu({
                    items = servers,
                    value = LrView.bind("serverUrl"),
                    fill_horizontal = 1,
                }),
            }))
        else
            table.insert(rows, f:row({
                f:static_text({ title = "Server:", alignment = "right",
                                width = LrView.share("ovLabel") }),
                f:static_text({
                    title = LrView.bind("serverUrl"),
                    fill_horizontal = 1,
                    truncation = "middle",
                }),
            }))
        end

        table.insert(rows, f:row({
            f:static_text({ title = "", width = LrView.share("ovLabel") }),
            f:static_text({
                title = LrView.bind("status"),
                font = "<system/small>",
                fill_horizontal = 1,
                truncation = "middle",
            }),
        }))

        if not util.nilOrEmpty(_G.prefs.import_folderPath) then
            table.insert(rows, f:row({
                f:static_text({ title = "RAW folder:", alignment = "right",
                                width = LrView.share("ovLabel") }),
                f:static_text({
                    title = tostring(_G.prefs.import_folderPath),
                    font = "<system/small>",
                    fill_horizontal = 1,
                    truncation = "middle",
                }),
            }))
        end

        table.insert(rows, f:separator({ fill_horizontal = 1 }))
        table.insert(rows, f:static_text({
            title = "To send finished edits back, export the photos with the PicPeak\n"
                .. "Exporter to the same event — each render replaces its proof in\n"
                .. "place and keeps the client's marks.",
            font = "<system/small>",
        }))

        table.insert(rows, f:row({
            f:push_button({
                title = "Open web interface",
                enabled = LrView.bind({
                    key = "serverUrl",
                    object = props,
                    transform = function(value) return not util.nilOrEmpty(value) end,
                }),
                action = function()
                    -- Safe inside the dialog: a browser is not a modal, so
                    -- this cannot deadlock the way opening another dialog here
                    -- would.
                    LrHttp.openUrlInBrowser(props.serverUrl)
                end,
            }),
        }))

        outcome = LrDialogs.presentModalDialog({
            title = "PicPeak Overview",
            contents = f:column(rows),
            actionVerb = "Import selections",
            otherVerb = "Config",
            cancelVerb = "Close",
        })
    end)

    if outcome == "ok" then return "import" end
    if outcome == "other" then return "config" end
    return nil
end

return PicPeakOverview
