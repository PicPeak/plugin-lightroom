--[[
    PicPeakAPI – Lua client for PicPeak v1 API.
    Authentication: Bearer token (Authorization: Bearer pp_live_xxx).
    Base path: /api/v1
]]

local API_BASE_PATH = "/api/v1"
local HTTP_TIMEOUT_DEFAULT = 30
local HTTP_TIMEOUT_UPLOAD = 300

local SUCCESS_STATUS_GET = 200
local SUCCESS_STATUS_POST = { [200] = true, [201] = true }
local SUCCESS_STATUS_CUSTOM = { [200] = true, [201] = true, [204] = true }

PicPeakAPI = {}
PicPeakAPI.__index = PicPeakAPI

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

local function safeDecodeJson(response, context)
    local ok, decoded = LrTasks.pcall(function()
        return JSON:decode(response or "{}")
    end)
    if not ok or decoded == nil then
        log:error("PicPeakAPI " .. context .. ": JSON decode failed: " .. tostring(decoded))
        return nil
    end
    return decoded
end

local function logRequestStart(api, method, apiPath)
    log:trace("PicPeakAPI: Preparing " .. method .. " request " .. api.url .. API_BASE_PATH .. apiPath)
end

local function handleRequestFailure(method, apiPath, status, headers, response)
    log:error(
        "PicPeakAPI "
            .. tostring(method)
            .. " request failed: "
            .. apiPath
            .. " (status "
            .. tostring(status or "?")
            .. ")"
    )
    if headers then
        log:error("Response headers: " .. util.dumpTable(headers))
    end
    local parsedErrorString = "HTTP " .. tostring(status or "Error")
    if response ~= nil then
        log:error("Response body: " .. tostring(response))
        local decoded = safeDecodeJson(response, "handleRequestFailure")
        if type(decoded) == "table" then
            local msg = decoded.error or decoded.message
            if type(msg) == "string" then
                parsedErrorString = parsedErrorString .. " - " .. msg
            end
        end
    end
    return parsedErrorString
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function PicPeakAPI:new(url, apiToken)
    local o = setmetatable({}, PicPeakAPI)
    o.url = (url ~= nil and type(url) == "string") and url or ""
    o.apiToken = (apiToken ~= nil and type(apiToken) == "string") and apiToken or ""
    return o
end

function PicPeakAPI:reconfigure(url, apiToken)
    self.url = (url ~= nil and type(url) == "string") and url or self.url or ""
    self.apiToken = (apiToken ~= nil and type(apiToken) == "string") and apiToken or self.apiToken or ""
    log:trace("PicPeak reconfigured with URL: " .. self.url)
end

-- ---------------------------------------------------------------------------
-- Headers
-- ---------------------------------------------------------------------------

function PicPeakAPI:createHeaders()
    local token = (self.apiToken ~= nil and type(self.apiToken) == "string") and self.apiToken or ""
    return {
        { field = "Authorization", value = "Bearer " .. token },
        { field = "Accept", value = "application/json" },
        { field = "Content-Type", value = "application/json" },
    }
end

function PicPeakAPI:createHeadersForMultipart()
    local token = (self.apiToken ~= nil and type(self.apiToken) == "string") and self.apiToken or ""
    return {
        { field = "Authorization", value = "Bearer " .. token },
        { field = "Accept", value = "application/json" },
    }
end

-- ---------------------------------------------------------------------------
-- URL sanitization & connectivity
-- ---------------------------------------------------------------------------

function PicPeakAPI:sanityCheckAndFixURL(url)
    if util.nilOrEmpty(url) then
        return false
    end
    if not string.match(url, "^https?://") then
        return nil
    end
    local sanitized = string.match(url, "^https?://[%w%.%-]+[:%d]*")
    if not sanitized then
        return nil
    end
    if string.len(sanitized) < string.len(url) then
        log:trace("sanityCheckAndFixURL: removed trailing path from URL.")
    end
    return sanitized
end

function PicPeakAPI:checkConnectivity()
    if util.nilOrEmpty(self.url) or util.nilOrEmpty(self.apiToken) then
        log:error("checkConnectivity: URL or API token is empty.")
        return false
    end

    local response, headers = LrHttp.get(
        self.url .. API_BASE_PATH .. "/events?limit=1",
        self:createHeaders()
    )

    if not headers then
        log:error("checkConnectivity: no response headers (network error or invalid URL)")
        return false
    end
    if headers.status == 200 then
        return true
    else
        log:error("checkConnectivity: test failed, status=" .. tostring(headers.status))
        if response then
            log:error("Response: " .. tostring(response))
        end
        local errReason = "HTTP " .. tostring(headers.status)
        return false, errReason
    end
end

-- ---------------------------------------------------------------------------
-- Dialog helpers
-- ---------------------------------------------------------------------------

local function _trimString(s)
    if type(s) ~= "string" then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

function PicPeakAPI.validateUrlForDialog(url, baseUrl, baseApiToken)
    local raw = (type(url) == "string") and url or ""
    local trimmed = _trimString(raw)
    if trimmed == "" then
        return false, url, "URL must not be empty. Example: https://photos.example.com"
    end
    local api = PicPeakAPI:new(baseUrl or "", baseApiToken or "")
    local result = api:sanityCheckAndFixURL(trimmed)
    if result == false then
        return false, url, "URL must not be empty. Example: https://photos.example.com"
    end
    if result == nil then
        return false, url, "Invalid URL format. Example: https://photos.example.com"
    end
    if result ~= trimmed then
        if LrDialogs and LrDialogs.message then
            LrDialogs.message("URL was autocorrected to: " .. result)
        end
    end
    return true, result, ""
end

function PicPeakAPI.testConnection(url, apiToken, existingApi)
    local u = _trimString(type(url) == "string" and url or "")
    local token = (type(apiToken) == "string") and apiToken or ""
    if u == "" or token == "" then
        return false, "Please enter URL and API token first.", nil
    end
    local api = existingApi
    if api and type(api.reconfigure) == "function" then
        api:reconfigure(u, token)
    else
        api = PicPeakAPI:new(u, token)
    end
    local ok, errReason = api:checkConnectivity()
    if ok then
        return true, "Connection test successful", api
    end
    return false, "Connection test failed: " .. tostring(errReason or "Check URL, API token, and network."), api
end

-- ---------------------------------------------------------------------------
-- Events (galleries)
-- ---------------------------------------------------------------------------

-- Returns paginated list of events as { title, value } table for popup menus.
-- Fetches up to maxEvents (default 100) events.
function PicPeakAPI:getEvents(maxEvents)
    maxEvents = maxEvents or 100
    local limit = math.min(maxEvents, 100)
    local path = "/events?limit=" .. limit .. "&page=1"
    local parsedResponse = self:doGetRequest(path)
    local events = {}
    if parsedResponse and type(parsedResponse.events) == "table" then
        for _, row in ipairs(parsedResponse.events) do
            if row and row.id and row.event_name then
                local dateStr = (row.event_date and type(row.event_date) == "string")
                    and (" – " .. string.sub(row.event_date, 1, 10))
                    or ""
                table.insert(events, { title = row.event_name .. dateStr, value = tostring(row.id) })
            end
        end
    end
    return events
end

-- Get event details by ID. Returns event table or nil.
function PicPeakAPI:getEvent(eventId)
    if util.nilOrEmpty(eventId) then
        log:warn("getEvent: eventId empty")
        return nil
    end
    return self:doGetRequest("/events/" .. tostring(eventId))
end

-- Check if an event exists on the server.
function PicPeakAPI:checkIfEventExists(eventId)
    if util.nilOrEmpty(eventId) then
        return false
    end
    local event = self:doGetRequestAllow404("/events/" .. tostring(eventId))
    return event ~= nil
end

-- Get event name by ID.
function PicPeakAPI:getEventName(eventId)
    local event = self:getEvent(eventId)
    return event and event.event_name or nil
end

-- Get event share URL.
function PicPeakAPI:getEventShareUrl(eventId)
    if util.nilOrEmpty(eventId) then
        return nil
    end
    local resp = self:doGetRequest("/events/" .. tostring(eventId) .. "/share-link")
    return resp and resp.share_url or nil
end

-- Create a new gallery event.
-- params table (all optional except event_name and event_type):
--   event_name, event_type, event_date,
--   customer_name, customer_email, customer_phone, admin_email,
--   require_password, password,
--   expires_at, feedback_enabled, color_theme
-- Returns: event id, share_url on success; nil on failure.
function PicPeakAPI:createEvent(params)
    if util.nilOrEmpty(params.event_name) then
        ErrorHandler.handleError("No event name given.", "createEvent: event_name empty")
        return nil
    end

    local body = {
        event_name = params.event_name,
        event_type = (not util.nilOrEmpty(params.event_type)) and params.event_type or "other",
    }

    -- Optional string fields: only include when non-empty
    local function addStr(key) if not util.nilOrEmpty(params[key]) then body[key] = params[key] end end
    addStr("event_date")
    addStr("customer_name")
    addStr("customer_email")
    addStr("customer_phone")
    addStr("admin_email")
    addStr("expires_at")
    addStr("color_theme")

    -- Password protection
    body.require_password = params.require_password and true or false
    if body.require_password and not util.nilOrEmpty(params.password) then
        body.password = params.password
    end

    -- Feedback (explicit boolean so server applies it vs inheriting the global default)
    if params.feedback_enabled ~= nil then
        body.feedback_enabled = params.feedback_enabled and true or false
    end

    log:trace("createEvent body: " .. JSON:encode(body))
    local parsedResponse = self:doPostRequest("/events", body)
    if parsedResponse and parsedResponse.id then
        log:info("createEvent: id=" .. tostring(parsedResponse.id) .. " slug=" .. tostring(parsedResponse.slug))
        return parsedResponse.id, parsedResponse.share_url
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Photos
-- ---------------------------------------------------------------------------

local MIME_TYPES = {
    jpg = "image/jpeg", jpeg = "image/jpeg",
    png = "image/png", tiff = "image/tiff", tif = "image/tiff",
    gif = "image/gif", webp = "image/webp", heic = "image/heic",
    heif = "image/heif", bmp = "image/bmp",
    -- The video types PicPeak accepts.
    mp4 = "video/mp4", m4v = "video/mp4", mov = "video/quicktime",
    webm = "video/webm", avi = "video/x-msvideo",
}

local function mimeTypeForFile(path)
    local ext = string.lower(string.match(path or "", "%.([^%.]+)$") or "")
    return MIME_TYPES[ext] or "image/jpeg"
end

-- Upload a single photo file to an event.
-- Returns: photo id (integer) on success, nil + errReason on failure.
--[[
    @param replacesPhotoId optional picpeak photo id this render replaces
           (PicPeak/picpeak#745). The id is read from the catalog photo's
           plugin metadata, so it survives the editor renaming the file —
           which is what makes it the reliable key rather than the filename.
]]
function PicPeakAPI:uploadPhoto(eventId, filePath, fileName, replacesPhotoId)
    if util.nilOrEmpty(eventId) then
        ErrorHandler.handleError("No event ID given.", "uploadPhoto: eventId empty")
        return nil, "No event ID"
    end
    if util.nilOrEmpty(filePath) then
        ErrorHandler.handleError("No file path given.", "uploadPhoto: filePath empty")
        return nil, "No file path"
    end

    local apiPath = "/events/" .. tostring(eventId) .. "/photos"
    local name = fileName or LrPathUtils.leafName(filePath)

    local mimeChunks = {
        {
            name = "photo",
            filePath = filePath,
            fileName = name,
            contentType = mimeTypeForFile(filePath),
        },
    }
    if replacesPhotoId ~= nil and replacesPhotoId ~= "" then
        table.insert(mimeChunks, {
            name = "replaces_photo_id",
            value = tostring(replacesPhotoId),
        })
    end

    local parsedResponse, errReason = self:doMultiPartPostRequest(apiPath, mimeChunks)
    if parsedResponse then
        -- A replace answers with { replaced = true, photo = {...} }; a fresh
        -- upload answers with the photo fields at the top level.
        if parsedResponse.replaced and parsedResponse.photo and parsedResponse.photo.id then
            log:info("uploadPhoto: " .. name .. " replaced id=" .. tostring(parsedResponse.photo.id))
            return parsedResponse.photo.id, nil, true
        end
        if parsedResponse.id then
            log:info("uploadPhoto: " .. name .. " -> id=" .. tostring(parsedResponse.id))
            return parsedResponse.id
        end
    end
    return nil, errReason
end

--[[
    Fetch an event's photos with their proofing marks (PicPeak/picpeak#745).

    Pages through GET /events/:id/photos until the server stops handing back
    rows. Paging is not optional politeness here — a wedding gallery is
    routinely well past the server's 100-per-page cap, and stopping at the
    first page would silently import a fraction of the picks.

    @param eventId
    @param filters table: markedOnly, markSource, colorLabels (csv string),
                          myColorLabels (csv), minRating, myMinRating
    @return array of photo tables, or nil + reason
]]
function PicPeakAPI:getEventPhotos(eventId, filters)
    if util.nilOrEmpty(eventId) then
        return nil, "No event ID"
    end
    filters = filters or {}

    local query = { "limit=100" }
    local function addParam(key, value)
        if value ~= nil and value ~= "" then
            table.insert(query, key .. "=" .. tostring(value))
        end
    end
    if filters.markedOnly then
        addParam("marked_only", "true")
    end
    addParam("mark_source", filters.markSource)
    addParam("color_labels", filters.colorLabels)
    addParam("my_color_labels", filters.myColorLabels)
    addParam("min_rating", filters.minRating)
    addParam("my_min_rating", filters.myMinRating)

    local photos = {}
    local page = 1
    -- Hard stop as a runaway guard: a server that always reports another page
    -- would otherwise loop forever inside an async task the user cannot
    -- cancel. 200 pages x 100 = 20000 photos, well past any real gallery.
    local MAX_PAGES = 200

    while page <= MAX_PAGES do
        local path = "/events/" .. tostring(eventId) .. "/photos?"
            .. table.concat(query, "&") .. "&page=" .. page
        local parsed, errReason = self:doGetRequest(path)
        if not parsed then
            -- Partial results are worse than none: the caller would apply
            -- labels to some photos and report success for all of them.
            return nil, errReason or "Failed to fetch photos"
        end
        if type(parsed.photos) ~= "table" or #parsed.photos == 0 then
            break
        end
        for _, row in ipairs(parsed.photos) do
            table.insert(photos, row)
        end
        local pagination = parsed.pagination
        if type(pagination) ~= "table" or pagination.pages == nil
            or page >= tonumber(pagination.pages) then
            break
        end
        page = page + 1
    end

    log:info("getEventPhotos: " .. #photos .. " photo(s) for event " .. tostring(eventId))
    return photos
end

-- ---------------------------------------------------------------------------
-- Sign-in: credentials in, API token out
-- ---------------------------------------------------------------------------
--[[
    The admin JWT expires in 24h, so the plugin cannot simply keep it — and
    keeping the PASSWORD instead would be strictly worse than a token:
    unscoped, unrevocable without a global password change, and it unlocks the
    web UI too. So credentials are used exactly once, exchanged for a
    revocable API token, and then discarded.

    These three endpoints live OUTSIDE /api/v1, so they bypass API_BASE_PATH.
]]

local AUTH_BASE_PATH = "/api/auth"
local ADMIN_BASE_PATH = "/api/admin"

-- POST to an absolute path with an explicit header set. The regular
-- doPostRequest() is hard-wired to API_BASE_PATH and to the stored API token,
-- neither of which applies while signing in.
--
-- Returns the decoded body, the status, a transport error, and the RAW headers
-- — the headers matter because the admin JWT never appears in the body.
local function postToPath(url, fullPath, body, headers)
    local response, respHeaders = LrHttp.post(
        url .. fullPath,
        JSON:encode(body),
        headers,
        "POST",
        HTTP_TIMEOUT_DEFAULT
    )
    if not respHeaders then
        return nil, 0, "No response from PicPeak server. Check the URL and your network."
    end
    local parsed = nil
    if response and response ~= "" then
        local ok, decoded = LrTasks.pcall(function() return JSON:decode(response) end)
        if ok then parsed = decoded end
    end
    return parsed, respHeaders.status or 0, nil, respHeaders
end

--[[
    Pull the admin JWT out of the response headers.

    /api/auth/admin/login answers `{ user: {...} }` and puts the token in an
    httpOnly `admin_token` cookie — it is NOT in the JSON body. Verified
    against a live server; reading a body field here silently never works.

    adminAuth accepts `Authorization: Bearer <jwt>` as well as the cookie
    (utils/tokenUtils.getAdminTokenFromRequest), so lifting the value out of
    the cookie and sending it as a Bearer header is all that is needed — no
    cookie jar.
]]
local function jwtFromHeaders(respHeaders)
    if type(respHeaders) ~= "table" then
        return nil
    end
    for _, header in ipairs(respHeaders) do
        if header.field and header.value
            and string.lower(tostring(header.field)) == "set-cookie" then
            local token = tostring(header.value):match("admin_token=([^;]+)")
            if token and token ~= "" then
                return token
            end
        end
    end
    return nil
end

local function jsonHeaders()
    return {
        { field = "Accept", value = "application/json" },
        { field = "Content-Type", value = "application/json" },
    }
end

--[[
    Step 1. Returns one of:
      { ok = true, jwt = "..." }
      { mfaRequired = true, mfaToken = "..." }
      { ok = false, message = "...", canRetry = bool, needsToken = bool }

    `needsToken` means password sign-in cannot work on this server at all —
    SSO enforced or reCAPTCHA enabled — and the caller should send the user to
    the Advanced token field rather than letting them retype their password.
]]
function PicPeakAPI.login(url, username, password)
    if util.nilOrEmpty(url) then
        return { ok = false, message = "Enter the PicPeak server URL first." }
    end
    if util.nilOrEmpty(username) or util.nilOrEmpty(password) then
        return { ok = false, message = "Enter your PicPeak email and password." }
    end

    local parsed, status, transportError, respHeaders = postToPath(
        url, AUTH_BASE_PATH .. "/admin/login",
        { username = username, password = password },
        jsonHeaders()
    )
    if transportError then
        return { ok = false, message = transportError }
    end

    if status == 200 then
        -- The MFA hand-off IS in the body; only the final JWT is a cookie.
        if parsed and parsed.mfaRequired and parsed.mfaToken then
            return { mfaRequired = true, mfaToken = parsed.mfaToken }
        end
        local jwt = jwtFromHeaders(respHeaders)
        if jwt then
            return { ok = true, jwt = jwt }
        end
        return { ok = false, message = "PicPeak accepted the login but sent no session cookie." }
    end

    if status == 403 and parsed and parsed.code == "LOCAL_LOGIN_DISABLED" then
        return {
            ok = false,
            needsToken = true,
            message = "This server signs in through SSO, so the plugin cannot use "
                .. "a password. Open Advanced and paste an API token created in "
                .. "PicPeak -> Settings -> API Tokens.",
        }
    end
    if status == 400 then
        -- The login route verifies reCAPTCHA before anything else when the
        -- admin has enabled it. There is no way to solve one from Lua.
        return {
            ok = false,
            needsToken = true,
            message = "This server requires reCAPTCHA on login, which the plugin "
                .. "cannot complete. Open Advanced and paste an API token created "
                .. "in PicPeak -> Settings -> API Tokens.",
        }
    end
    if status == 423 then
        local retryAfter = parsed and parsed.retryAfter
        return {
            ok = false,
            message = "That account is temporarily locked after too many failed "
                .. "attempts." .. (retryAfter and (" Try again in about "
                .. tostring(math.ceil(tonumber(retryAfter) or 0)) .. "s.") or ""),
        }
    end
    if status == 401 then
        return { ok = false, canRetry = true, message = "Wrong email or password." }
    end

    return { ok = false, message = "Sign-in failed (HTTP " .. tostring(status) .. ")." }
end

-- Step 1b: exchange the short-lived mfa_pending token plus a TOTP or recovery
-- code for a full admin JWT.
function PicPeakAPI.submitMfa(url, mfaToken, code)
    if util.nilOrEmpty(code) then
        return { ok = false, message = "Enter the code from your authenticator app." }
    end
    local _, status, transportError, respHeaders = postToPath(
        url, AUTH_BASE_PATH .. "/admin/login/mfa",
        { mfaToken = mfaToken, code = code },
        jsonHeaders()
    )
    if transportError then
        return { ok = false, message = transportError }
    end
    if status == 200 then
        local jwt = jwtFromHeaders(respHeaders)
        if jwt then
            return { ok = true, jwt = jwt }
        end
    end
    if status == 401 then
        return { ok = false, canRetry = true, message = "That code was not accepted." }
    end
    return { ok = false, message = "Two-factor verification failed (HTTP " .. tostring(status) .. ")." }
end

--[[
    Step 2: mint the long-lived API token the plugin actually stores.

    Named per machine so it is identifiable and individually revocable in
    Settings -> API Tokens, and given an expiry rather than living forever:
    LrPrefs is not the OS keychain, and an admin-scoped token in a plaintext
    prefs file is effectively full account access.
]]
function PicPeakAPI.createApiToken(url, jwt, tokenName, expiresAt)
    local parsed, status, transportError = postToPath(
        url, ADMIN_BASE_PATH .. "/api-tokens",
        { name = tokenName, scopes = { "admin" }, expires_at = expiresAt },
        {
            { field = "Authorization", value = "Bearer " .. tostring(jwt) },
            { field = "Accept", value = "application/json" },
            { field = "Content-Type", value = "application/json" },
        }
    )
    if transportError then
        return { ok = false, message = transportError }
    end
    if (status == 200 or status == 201) and parsed and parsed.token then
        return { ok = true, token = parsed.token, id = parsed.id, expiresAt = parsed.expires_at }
    end
    if status == 403 then
        return {
            ok = false,
            needsToken = true,
            message = "Your PicPeak account cannot create API tokens (it lacks the "
                .. "'settings.integrations' permission). Ask an administrator for a "
                .. "token and paste it under Advanced.",
        }
    end
    return { ok = false, message = "Could not create an API token (HTTP " .. tostring(status) .. ")." }
end

-- Revoking needs a JWT: the admin routes are JWT-only, so an API token cannot
-- delete itself. Sign-out therefore either forgets the token locally or asks
-- for the password again to revoke it properly.
function PicPeakAPI.revokeApiToken(url, jwt, tokenId)
    if tokenId == nil then
        return { ok = false, message = "No stored token id to revoke." }
    end
    local response, headers = LrHttp.post(
        url .. ADMIN_BASE_PATH .. "/api-tokens/" .. tostring(tokenId),
        "",
        {
            { field = "Authorization", value = "Bearer " .. tostring(jwt) },
            { field = "Accept", value = "application/json" },
        },
        "DELETE",
        HTTP_TIMEOUT_DEFAULT
    )
    if not headers then
        return { ok = false, message = "No response from PicPeak server." }
    end
    if SUCCESS_STATUS_CUSTOM[headers.status] then
        return { ok = true }
    end
    return { ok = false, message = "Could not revoke the token (HTTP " .. tostring(headers.status) .. ")." }
end

-- ---------------------------------------------------------------------------
-- HTTP request layer
-- ---------------------------------------------------------------------------

function PicPeakAPI:doGetRequest(apiPath)
    logRequestStart(self, "GET", apiPath)
    local response, headers = LrHttp.get(
        self.url .. API_BASE_PATH .. apiPath,
        self:createHeaders()
    )

    if not headers then
        log:error("PicPeakAPI GET: no response headers (network error): " .. apiPath)
        ErrorHandler.handleError("No response from PicPeak server. Check URL and network.", "Connection failed")
        return nil
    end
    if headers.status == SUCCESS_STATUS_GET then
        log:trace("PicPeakAPI GET request succeeded")
        return safeDecodeJson(response, "GET")
    end
    local errReason = handleRequestFailure("GET", apiPath, headers.status, headers, response)
    return nil, errReason
end

function PicPeakAPI:doGetRequestAllow404(apiPath)
    logRequestStart(self, "GET", apiPath)
    local response, headers = LrHttp.get(
        self.url .. API_BASE_PATH .. apiPath,
        self:createHeaders()
    )

    if not headers then
        log:error("PicPeakAPI GET: no response headers: " .. apiPath)
        return nil
    end
    if headers.status == SUCCESS_STATUS_GET then
        return safeDecodeJson(response, "GET")
    end
    if headers.status == 404 or headers.status == 400 then
        log:trace("PicPeakAPI GET: resource not found (" .. tostring(headers.status) .. "): " .. apiPath)
        return nil
    end
    handleRequestFailure("GET", apiPath, headers.status, headers, response)
    return nil
end

function PicPeakAPI:doPostRequest(apiPath, postBody)
    logRequestStart(self, "POST", apiPath)
    if postBody ~= nil then
        log:trace("PicPeakAPI: POST body " .. JSON:encode(postBody))
    end
    local response, headers = LrHttp.post(
        self.url .. API_BASE_PATH .. apiPath,
        JSON:encode(postBody),
        self:createHeaders(),
        "POST",
        HTTP_TIMEOUT_DEFAULT
    )

    if not headers then
        log:error("PicPeakAPI POST: no response headers: " .. apiPath)
        ErrorHandler.handleError("No response from PicPeak server. Check URL and network.", "Connection failed")
        return nil
    end
    if SUCCESS_STATUS_POST[headers.status] then
        log:trace("PicPeakAPI POST request succeeded")
        return safeDecodeJson(response, "POST")
    end
    local errReason = handleRequestFailure("POST", apiPath, headers.status, headers, response)
    return nil, errReason
end

function PicPeakAPI:doMultiPartPostRequest(apiPath, mimeChunks)
    logRequestStart(self, "multipart POST", apiPath)
    local response, headers = LrHttp.postMultipart(
        self.url .. API_BASE_PATH .. apiPath,
        mimeChunks,
        self:createHeadersForMultipart(),
        HTTP_TIMEOUT_UPLOAD
    )

    if not headers then
        log:error("PicPeakAPI multipart POST: no response headers: " .. apiPath)
        ErrorHandler.handleError("No response from PicPeak server. Check URL and network.", "Connection failed")
        return nil
    end
    if SUCCESS_STATUS_POST[headers.status] then
        return safeDecodeJson(response, "multipart POST")
    end
    local errReason = handleRequestFailure("multipart POST", apiPath, headers.status, headers, response)
    return nil, errReason
end
