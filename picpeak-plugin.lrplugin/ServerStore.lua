--[[
    The list of PicPeak servers this install knows about.

    The plugin used to hold exactly one `prefs.url`. A photographer can
    reasonably work against more than one — a studio server and a client's, or
    production and a local test instance — so the overview lets them switch.

    Storage: a JSON string in prefs rather than a Lua table. LrPrefs round-trips
    scalars dependably; a nested table is the kind of thing that comes back as
    something else after a plugin update and takes every server with it. A
    string that fails to parse degrades to "no servers yet", which is
    recoverable by signing in again — and the ACTIVE server is kept in the
    original scalar `prefs.url`, so an install that predates this keeps working
    and a corrupt list never disconnects it.

    Tokens are NOT here. TokenStore keys the keychain by server URL, so each
    server already carries its own credential.
]]

ServerStore = {}

local LIST_KEY = "serverList"

local function normalize(url)
    if type(url) ~= "string" then return nil end
    local trimmed = url:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
    if trimmed == "" then return nil end
    return trimmed
end

--- @return array of server URLs, active one first
function ServerStore.list()
    local raw = _G.prefs[LIST_KEY]
    local servers = {}
    if type(raw) == "string" and raw ~= "" then
        local ok, decoded = LrTasks.pcall(function() return JSON:decode(raw) end)
        if ok and type(decoded) == "table" then
            for _, url in ipairs(decoded) do
                local n = normalize(url)
                if n then table.insert(servers, n) end
            end
        else
            log:warn("ServerStore: server list unreadable, starting a fresh one")
        end
    end

    -- The active server is always in the list even if the list was lost: it is
    -- the one the user is actually connected to, and omitting it would show an
    -- empty picker to someone who is signed in.
    local active = normalize(_G.prefs.url)
    if active then
        local seen = false
        for _, url in ipairs(servers) do
            if url == active then seen = true break end
        end
        if not seen then table.insert(servers, 1, active) end
    end
    return servers
end

function ServerStore.add(url)
    local n = normalize(url)
    if not n then return false end
    local servers = ServerStore.list()
    for _, existing in ipairs(servers) do
        if existing == n then return true end
    end
    table.insert(servers, n)
    local ok = LrTasks.pcall(function()
        _G.prefs[LIST_KEY] = JSON:encode(servers)
    end)
    if not ok then
        log:error("ServerStore: could not save the server list")
        return false
    end
    return true
end

--- Switch which server the plugin talks to. Its token is already in the
--- keychain under that URL, so nothing else has to move.
function ServerStore.setActive(url)
    local n = normalize(url)
    if not n then return false end
    _G.prefs.url = n
    ServerStore.add(n)
    return true
end

function ServerStore.getActive()
    return normalize(_G.prefs.url) or ""
end

--- Items for an LrView popup_menu.
function ServerStore.menuItems()
    local items = {}
    for _, url in ipairs(ServerStore.list()) do
        table.insert(items, { title = url, value = url })
    end
    return items
end

return ServerStore
