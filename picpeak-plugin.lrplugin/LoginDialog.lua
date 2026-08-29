--[[
    Sign in with PicPeak credentials and store only the resulting API token
    (PicPeak/picpeak#745).

    The password never reaches LrPrefs. It is used for one request, exchanged
    for a revocable API token, and dropped — see PicPeakAPI.login for why the
    JWT cannot simply be kept instead (it expires in 24h).
]]

require("PicPeakAPI")

LoginDialog = {}

-- A year by default. LrPrefs is not the OS keychain, so an admin-scoped token
-- sitting in a plaintext prefs file is effectively full account access; an
-- expiry bounds that without making the user re-authenticate often.
local DEFAULT_EXPIRY_DAYS = 365

local function isoExpiry(days)
    if days == nil or days <= 0 then
        return nil
    end
    -- LrDate works in seconds since 2001-01-01; timeToIsoDate gives a date
    -- string, which is what the API's isISO8601 validator accepts.
    local target = LrDate.currentTime() + (days * 24 * 60 * 60)
    return LrDate.timeToIsoDate(target)
end

local function machineTokenName()
    local host = nil
    local ok, value = LrTasks.pcall(function()
        return LrSystemInfo.summaryString()
    end)
    if ok and type(value) == "string" and value ~= "" then
        host = value:match("^[^,\n]+")
    end
    return "Lightroom" .. (host and (" — " .. host) or "")
end

-- Prompt for the second factor. Separate dialog because it only appears for
-- accounts that actually enrolled TOTP.
--
-- The property table must come from LrBinding — LrView.bind only observes
-- those, and binding a plain Lua table silently never updates.
local function promptForMfa(f, url, mfaToken)
    local result = nil
    LrFunctionContext.callWithContext("picpeakMfaPrompt", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.code = ""

        local contents = f:column({
            spacing = f:control_spacing(),
            bind_to_object = props,
            f:static_text({ title = "Enter the 6-digit code from your authenticator app." }),
            f:static_text({
                title = "A recovery code works too.",
                font = "<system/small>",
            }),
            f:edit_field({
                value = LrView.bind("code"),
                width_in_chars = 12,
                immediate = true,
            }),
        })

        local button = LrDialogs.presentModalDialog({
            title = "Two-factor verification",
            contents = contents,
            actionVerb = "Verify",
        })
        if button == "ok" then
            result = { code = props.code }
        end
    end)

    if result == nil then
        return nil
    end
    return PicPeakAPI.submitMfa(url, mfaToken, result.code)
end

--[[
    sanityCheckAndFixURL accepts `^https?://`, so the password can be sent over
    a cleartext connection. That is legitimate for localhost and for a server
    reached over a VPN or SSH tunnel, so it is a warning rather than a refusal
    — but the user is about to type an administrator password, and they should
    know before they do, not after.

    Loopback is exempt: it never leaves the machine, and warning about it would
    train people to ignore the warning that matters.
]]
local function isInsecureUrl(url)
    if type(url) ~= "string" or url == "" then
        return false
    end
    if url:match("^https://") then
        return false
    end
    local host = url:match("^https?://([^:/]+)")
    if host then
        host = host:lower()
        if host == "localhost" or host == "127.0.0.1" or host == "::1"
            or host:match("%.localhost$") then
            return false
        end
    end
    return true
end

-- Collect an email + password once. Returns nil when the user cancels.
local function promptForCredentials(f, title, blurb, actionVerb, url)
    local creds = nil
    LrFunctionContext.callWithContext("picpeakCredentialsPrompt", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.username = ""
        props.password = ""

        local contents = f:column({
            spacing = f:control_spacing(),
            bind_to_object = props,
            f:static_text({ title = blurb }),
            f:row({
                f:static_text({ title = "Email:", alignment = "right", width = LrView.share("loginLabel") }),
                f:edit_field({ value = LrView.bind("username"), fill_horizontal = 1, immediate = true }),
            }),
            f:row({
                f:static_text({ title = "Password:", alignment = "right", width = LrView.share("loginLabel") }),
                f:password_field({ value = LrView.bind("password"), fill_horizontal = 1, immediate = true }),
            }),
            f:static_text({
                title = "Your password is used once and is never stored.",
                font = "<system/small>",
            }),
            f:static_text({
                title = "⚠  This server is not using https — your password would be "
                    .. "sent unencrypted.\nOnly continue on a network you trust "
                    .. "(a VPN or SSH tunnel), or switch the URL to https://.",
                font = "<system/small>",
                text_color = LrColor(0.7, 0.25, 0),
                visible = isInsecureUrl(url),
                fill_horizontal = 1,
                height_in_lines = 2,
            }),
        })

        local button = LrDialogs.presentModalDialog({
            title = title,
            contents = contents,
            actionVerb = actionVerb,
        })
        if button == "ok" then
            creds = { username = props.username, password = props.password }
        end
    end)
    return creds
end

--[[
    Run the whole sign-in. Returns a table:
      { ok = true, token = "pp_live_...", tokenId = n, username = "...", expiresAt = "..." }
      { ok = false, message = "...", needsToken = bool }

    `needsToken` tells the caller to open the Advanced section: password
    sign-in cannot work on this server at all.
]]
function LoginDialog.signIn(url)
    local f = LrView.osFactory()
    local creds = promptForCredentials(
        f,
        "Sign in to PicPeak",
        "Sign in with your PicPeak administrator account.",
        "Sign in",
        url
    )
    if creds == nil then
        return { ok = false, canceled = true }
    end

    local login = PicPeakAPI.login(url, creds.username, creds.password)
    if login.mfaRequired then
        login = promptForMfa(f, url, login.mfaToken)
        if login == nil then
            return { ok = false, canceled = true }
        end
    end
    if not login.ok then
        return login
    end

    local created = PicPeakAPI.createApiToken(
        url, login.jwt, machineTokenName(), isoExpiry(DEFAULT_EXPIRY_DAYS)
    )
    if not created.ok then
        return created
    end

    return {
        ok = true,
        token = created.token,
        tokenId = created.id,
        expiresAt = created.expiresAt,
        username = creds.username,
    }
end

--[[
    Revoke the stored token server-side. The admin routes are JWT-only, so an
    API token cannot delete itself — the password is needed again. Callers
    offer this as a distinct "sign out and revoke" action; plain sign-out just
    forgets the token locally.
]]
function LoginDialog.signOutAndRevoke(url, tokenId)
    local f = LrView.osFactory()
    local creds = promptForCredentials(
        f,
        "Revoke PicPeak token",
        "Confirm your password to revoke this token on the server.",
        "Revoke",
        url
    )
    if creds == nil then
        return { ok = false, canceled = true }
    end

    local login = PicPeakAPI.login(url, creds.username, creds.password)
    if login.mfaRequired then
        login = promptForMfa(f, url, login.mfaToken)
        if login == nil then
            return { ok = false, canceled = true }
        end
    end
    if not login.ok then
        return login
    end

    return PicPeakAPI.revokeApiToken(url, login.jwt, tokenId)
end

return LoginDialog
