--[[
    Regression guard for TokenStore (issue 7).

    TokenStore moves the API token out of plaintext prefs into the keychain
    and clears the prefs copy. PicPeak shows a token exactly once, so a wrong
    migration signs the user out holding a token they can never see again.
    These checks stub the three SDK globals TokenStore touches (prefs,
    LrTasks.pcall, LrPasswords) and run it outside Lightroom.

    Run from the repository root with any Lua 5.1+ interpreter:

        lua tests/token_store_test.lua

    Exits non-zero when a check fails.
]]

local PLUGIN_DIR = "picpeak-plugin.lrplugin/"

local failures, passes = 0, 0

local function check(name, condition, detail)
    if condition then
        passes = passes + 1
    else
        failures = failures + 1
        print("FAIL  " .. name .. (detail and ("  (" .. detail .. ")") or ""))
    end
end

-- Fresh SDK stubs and a freshly loaded TokenStore for every case, so no state
-- leaks from one check into the next.
local function setup(options)
    options = options or {}
    local keychain = {}
    local logged = {}

    _G.prefs = { apiToken = options.legacy }
    _G.LrTasks = { pcall = pcall }
    _G.LrPasswords = {
        store = function(key, value)
            if options.refuseStore then error("keychain refused the write") end
            keychain[key] = value
        end,
        retrieve = function(key)
            if options.refuseRead then error("keychain refused the read") end
            return keychain[key]
        end,
    }
    local function record(level) return function(_, message) logged[#logged + 1] = level .. ": " .. message end end
    _G.log = { info = record("info"), warn = record("warn"), error = record("error") }

    _G.TokenStore = nil
    dofile(PLUGIN_DIR .. "TokenStore.lua")
    return keychain, logged
end

local URL = "https://gallery.example.com"
local OTHER = "https://other.example.com"

-- Migration ------------------------------------------------------------------

do
    local keychain = setup({ legacy = "pp_live_old" })
    local token = TokenStore.get(URL)
    check("migration returns the legacy token", token == "pp_live_old", tostring(token))
    check("migration writes it to the keychain under the server key",
        keychain["picpeak:apiToken:" .. URL] == "pp_live_old")
    check("migration clears the plaintext prefs copy", _G.prefs.apiToken == "")
    check("after migration the token is read from the keychain", TokenStore.get(URL) == "pp_live_old")
end

-- No URL yet: never migrate under an empty key -------------------------------

do
    local keychain = setup({ legacy = "pp_live_old" })
    -- Indexed by hand: ipairs would stop at the leading nil.
    local noUrls = { nil, "", "   ", "///" }
    for i = 1, 4 do
        local token = TokenStore.get(noUrls[i])
        check("no-URL read still returns the prefs token (" .. tostring(noUrls[i]) .. ")", token == "pp_live_old")
    end
    check("no-URL read leaves the prefs copy in place", _G.prefs.apiToken == "pp_live_old")
    check("no-URL read writes nothing to the keychain", next(keychain) == nil)
    check("the token migrates once a URL is known", TokenStore.get(URL) == "pp_live_old"
        and keychain["picpeak:apiToken:" .. URL] == "pp_live_old" and _G.prefs.apiToken == "")
end

-- A keychain that refuses -----------------------------------------------------

do
    local keychain, logged = setup({ legacy = "pp_live_old", refuseStore = true })
    local token = TokenStore.get(URL)
    check("refused migration keeps working from prefs", token == "pp_live_old")
    check("refused migration does not clear the prefs copy", _G.prefs.apiToken == "pp_live_old")
    check("refused migration stores nothing", next(keychain) == nil)
    check("refused migration logs a warning", #logged == 1 and logged[1]:match("^warn") ~= nil, logged[1])
end

do
    setup({ refuseRead = true })
    check("a failing keychain read answers an empty token", TokenStore.get(URL) == "")
end

do
    setup({ refuseStore = true })
    _G.prefs.apiToken = ""
    check("set reports a refused write", TokenStore.set(URL, "pp_live_new") == false)
end

-- Per-server isolation and URL normalisation ----------------------------------

do
    setup()
    TokenStore.set(URL, "pp_live_a")
    TokenStore.set(OTHER, "pp_live_b")
    check("each server keeps its own token", TokenStore.get(URL) == "pp_live_a" and TokenStore.get(OTHER) == "pp_live_b")
    check("an unknown server has no token", TokenStore.get("https://third.example.com") == "")
end

do
    local keychain = setup()
    TokenStore.set(URL .. "/", "pp_live_a")
    check("a trailing slash names the same entry", TokenStore.get(URL) == "pp_live_a")
    check("surrounding space names the same entry", TokenStore.get("  " .. URL .. "//  ") == "pp_live_a")
    local entries = 0
    for _ in pairs(keychain) do entries = entries + 1 end
    check("only one keychain entry exists for that server", entries == 1, tostring(entries))
end

-- set and clear never leave a plaintext copy -----------------------------------

do
    setup({ legacy = "" })
    _G.prefs.apiToken = "pp_live_stale"
    -- A stale prefs copy would be read (and migrated) by get first, so write
    -- through set directly, as a re-sign-in does.
    check("set succeeds", TokenStore.set(URL, "pp_live_new") == true)
    check("set clears a stale prefs copy", _G.prefs.apiToken == "")
    check("set stores the new token", TokenStore.get(URL) == "pp_live_new")
end

do
    setup()
    TokenStore.set(URL, "pp_live_a")
    TokenStore.set(OTHER, "pp_live_b")
    _G.prefs.apiToken = "pp_live_stale"
    TokenStore.clear(URL)
    check("clear empties that server's token", TokenStore.get(URL) == "")
    check("clear leaves other servers alone", TokenStore.get(OTHER) == "pp_live_b")
    check("clear removes the prefs copy", _G.prefs.apiToken == "")
end

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then os.exit(1) end
