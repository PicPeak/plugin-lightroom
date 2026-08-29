require("PicPeakAPI")
require("LoginDialog")
require("TokenStore")
require("ServerStore")

SharedDialogSections = {}

-- PicPeak event types for UI menus
SharedDialogSections.EVENT_TYPES = {
    { title = "Other", value = "other" },
    { title = "Wedding", value = "wedding" },
    { title = "Birthday", value = "birthday" },
    { title = "Corporate", value = "corporate" },
    { title = "Family", value = "family" },
}

--[[
    Seed a dialog's connection fields from prefs, and write any change back.

    The Export and Publish dialogs keep `url` / `apiToken` on their own
    property tables, and `prefs.url` was never written by anything. So a user
    who configured the connection in the Export dialog still had an empty
    `prefs.url`, and the Import menu item — which has no export settings to
    read — refused with "PicPeak is not connected yet".

    Every surface now reads and writes the same two prefs.
]]
function SharedDialogSections.syncConnectionPrefs(propertyTable)
    if util.nilOrEmpty(propertyTable.url) then
        propertyTable.url = _G.prefs.url or ""
    end
    if util.nilOrEmpty(propertyTable.apiToken) then
        -- Keychain, not prefs. Migrates a legacy plaintext token on first read.
        propertyTable.apiToken = TokenStore.get(propertyTable.url or _G.prefs.url) or ""
    end
    propertyTable:addObserver("url", function(props)
        _G.prefs.url = props.url or ""
    end)
    propertyTable:addObserver("apiToken", function(props)
        TokenStore.set(props.url or _G.prefs.url, props.apiToken or "")
    end)
end

--[[
    The connection controls as a plain list of rows.

    Split out from the section wrapper below so the same controls can serve
    three containers that differ: the Export dialog and the Plug-in Manager
    want a *section* (a table carrying `title` and `bind_to_object`), while
    the PicPeak hub needs them inside an ordinary column in a modal dialog.
    Building them twice would guarantee the two drifted.
]]
function SharedDialogSections.getConnectionRows(f, propertyTable)
    local section = SharedDialogSections.getServerConnectionSection(f, propertyTable)
    local rows = {}
    for _, row in ipairs(section) do
        table.insert(rows, row)
    end
    return rows
end

-- Generate the 'PicPeak Server connection' dialog section
--
-- Signing in with an email and password is the standard path (#745): the
-- plugin exchanges the credentials for an API token once and stores only the
-- token, so the user never handles one. Token entry still exists, behind
-- Advanced, because password sign-in is impossible on servers that enforce
-- SSO or enable reCAPTCHA — and because anyone already using a pasted token
-- must keep working after upgrading.
function SharedDialogSections.getServerConnectionSection(f, propertyTable)
    local bind = LrView.bind
    local share = LrView.share

    -- Seed the sign-in state from prefs so the section shows who is signed in
    -- rather than an empty line on every reopen.
    propertyTable.signedInAs = _G.prefs.signedInAs or ""
    propertyTable.tokenExpiresAt = _G.prefs.tokenExpiresAt or ""
    propertyTable.showAdvanced = _G.prefs.showAdvanced or false

    local function statusTitle(signedInAs, apiToken)
        if signedInAs ~= nil and signedInAs ~= "" then
            local expiry = propertyTable.tokenExpiresAt
            if expiry ~= nil and expiry ~= "" then
                return "Signed in as " .. signedInAs .. " — token expires "
                    .. string.sub(tostring(expiry), 1, 10)
            end
            return "Signed in as " .. signedInAs
        end
        if apiToken ~= nil and apiToken ~= "" then
            return "Connected with a manually entered API token."
        end
        return "Not signed in."
    end

    return {
        title = "PicPeak Server connection",
        bind_to_object = propertyTable,
        f:row({
            f:static_text({
                title = "URL:",
                alignment = "right",
                width = share("labelWidth"),
            }),
            f:edit_field({
                value = bind("url"),
                truncation = "middle",
                immediate = false,
                fill_horizontal = 1,
                validate = function(_, url)
                    return PicPeakAPI.validateUrlForDialog(url, propertyTable.url, propertyTable.apiToken)
                end,
            }),
            f:push_button({
                title = "Test connection",
                action = function()
                    LrTasks.startAsyncTask(function()
                        local _, message, api =
                            PicPeakAPI.testConnection(propertyTable.url, propertyTable.apiToken, propertyTable.picpeak)
                        if api then
                            propertyTable.picpeak = api
                        end
                        LrDialogs.message(message)
                    end)
                end,
            }),
        }),

        f:row({
            f:static_text({ title = "", alignment = "right", width = share("labelWidth") }),
            f:static_text({
                title = bind({
                    keys = { "signedInAs", "apiToken" },
                    operation = function(_, values)
                        return statusTitle(values.signedInAs, values.apiToken)
                    end,
                }),
                fill_horizontal = 1,
                font = "<system/small>",
            }),
        }),

        f:row({
            f:static_text({ title = "", alignment = "right", width = share("labelWidth") }),
            f:push_button({
                title = "Sign in…",
                action = function()
                    LrTasks.startAsyncTask(function()
                        local result = LoginDialog.signIn(propertyTable.url)
                        if result.canceled then
                            return
                        end
                        if result.ok then
                            propertyTable.apiToken = result.token
                            propertyTable.signedInAs = result.username
                            propertyTable.tokenExpiresAt = result.expiresAt or ""
                            _G.prefs.url = propertyTable.url or ""
                            TokenStore.set(propertyTable.url, result.token)
                            -- Remember it so the overview can offer it later.
                            ServerStore.add(propertyTable.url)
                            _G.prefs.apiTokenId = result.tokenId
                            _G.prefs.signedInAs = result.username
                            _G.prefs.tokenExpiresAt = result.expiresAt or ""
                            LrDialogs.message(
                                "Signed in to PicPeak",
                                "The plugin created an API token for this machine. You can "
                                    .. "revoke it any time in PicPeak → Settings → API Tokens.",
                                "info"
                            )
                        else
                            -- Password sign-in cannot work on this server at
                            -- all. Open Advanced rather than leaving the user
                            -- staring at a failure with no visible way on.
                            if result.needsToken then
                                propertyTable.showAdvanced = true
                                _G.prefs.showAdvanced = true
                            end
                            LrDialogs.message("Could not sign in", result.message or "Sign-in failed.", "warning")
                        end
                    end)
                end,
            }),
            f:push_button({
                title = "Sign out",
                enabled = bind({
                    key = "apiToken",
                    transform = function(value) return value ~= nil and value ~= "" end,
                }),
                action = function()
                    LrTasks.startAsyncTask(function()
                        -- The admin routes are JWT-only, so an API token
                        -- cannot delete itself. Be honest about that rather
                        -- than implying the token is gone from the server.
                        local choice = LrDialogs.confirm(
                            "Sign out of PicPeak",
                            "Forgetting the token here does not remove it from the server. "
                                .. "Revoke it too? That needs your password once more.",
                            "Revoke on server",
                            "Cancel",
                            "Just forget it here"
                        )
                        if choice == "cancel" then
                            return
                        end
                        if choice == "ok" then
                            local revoked = LoginDialog.signOutAndRevoke(
                                propertyTable.url, _G.prefs.apiTokenId
                            )
                            if revoked.canceled then
                                return
                            end
                            if not revoked.ok then
                                LrDialogs.message(
                                    "Could not revoke the token",
                                    (revoked.message or "Revoking failed.")
                                        .. "\n\nThe token has NOT been forgotten locally, so "
                                        .. "you can try again or remove it in PicPeak → "
                                        .. "Settings → API Tokens.",
                                    "warning"
                                )
                                return
                            end
                        end
                        propertyTable.apiToken = ""
                        propertyTable.signedInAs = ""
                        propertyTable.tokenExpiresAt = ""
                        TokenStore.clear(propertyTable.url)
                        _G.prefs.apiTokenId = nil
                        _G.prefs.signedInAs = ""
                        _G.prefs.tokenExpiresAt = ""
                    end)
                end,
            }),
            f:push_button({
                title = "Advanced",
                action = function()
                    propertyTable.showAdvanced = not propertyTable.showAdvanced
                    _G.prefs.showAdvanced = propertyTable.showAdvanced
                end,
            }),
        }),

        f:row({
            visible = bind("showAdvanced"),
            f:static_text({
                title = "API Token:",
                alignment = "right",
                width = share("labelWidth"),
            }),
            f:password_field({
                value = bind("apiToken"),
                truncation = "middle",
                immediate = false,
                fill_horizontal = 1,
            }),
        }),
        f:row({
            visible = bind("showAdvanced"),
            margin_top = 2,
            f:static_text({ title = "", alignment = "right", width = share("labelWidth") }),
            f:static_text({
                title = "Only needed if sign-in is unavailable — some servers enforce SSO "
                    .. "or reCAPTCHA. Create one in PicPeak → Settings → API Tokens with "
                    .. "the 'admin' scope.",
                alignment = "left",
                fill_horizontal = 1,
                font = "<system/small>",
            }),
        }),
    }
end

return SharedDialogSections
