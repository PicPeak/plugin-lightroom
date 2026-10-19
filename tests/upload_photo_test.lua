--[[
    Replace fallback and render-failure reporting.

    A re-publish sends the id recorded on the last publish as
    replaces_photo_id. When that photo is gone from PicPeak (deleted there, or
    the gallery was recreated), the server answers 404 and the plugin uploads
    the render as a new photo instead of failing on every re-publish. These
    checks stub LrHttp and the other SDK globals PicPeakAPI touches.

    Run from the repository root with any Lua 5.1+ interpreter:

        lua tests/upload_photo_test.lua
]]

local failures, passes = 0, 0

local function check(name, condition, detail)
    if condition then
        passes = passes + 1
    else
        failures = failures + 1
        print("FAIL  " .. name .. (detail and ("  (" .. detail .. ")") or ""))
    end
end

local function noop() end
_G.log = { trace = noop, info = noop, warn = noop, error = noop }
_G.LrTasks = { pcall = pcall }
_G.ErrorHandler = { handleError = noop }
_G.LrPathUtils = { leafName = function(p) return (p:match("[^/]+$")) end }
-- Responses are handed over as tables already; decode passes them through.
_G.JSON = { decode = function(_, response) return response end }

dofile("picpeak-plugin.lrplugin/util.lua")
dofile("picpeak-plugin.lrplugin/PicPeakAPI.lua")

-- Each call to postMultipart answers with the next scripted response and
-- records the replaces_photo_id it was sent.
local function serve(responses)
    local sent = {}
    _G.LrHttp = {
        postMultipart = function(_, chunks)
            local replaces = false
            for _, chunk in ipairs(chunks) do
                if chunk.name == "replaces_photo_id" then replaces = chunk.value end
            end
            sent[#sent + 1] = replaces
            local r = responses[#sent]
            return r.body, { status = r.status }
        end,
    }
    return sent
end

local api = PicPeakAPI:new("https://gallery.example.com", "pp_live_x")

do
    local sent = serve({ { status = 200, body = { replaced = true, photo = { id = 7 } } } })
    local id, err, replaced = api:uploadPhoto(3, "/tmp/r/IMG_1.jpg", "IMG_1.jpg", "7")
    check("a replace returns the photo id", id == 7, tostring(err))
    check("and says it replaced", replaced == true)
    check("one request, carrying the id", #sent == 1 and sent[1] == "7")
end

do
    local sent = serve({
        { status = 404, body = { error = "No photo 7 in event 3" } },
        { status = 201, body = { id = 12 } },
    })
    local id, err, replaced = api:uploadPhoto(3, "/tmp/r/IMG_1.jpg", "IMG_1.jpg", "7")
    check("a missing replace target falls back to a new upload", id == 12, tostring(err))
    check("which is not reported as a replacement", not replaced)
    check("the retry carries no replaces_photo_id", #sent == 2 and sent[1] == "7" and sent[2] == false)
end

do
    local sent = serve({ { status = 404, body = { error = "Event not found" } } })
    local id, err = api:uploadPhoto(3, "/tmp/r/IMG_1.jpg", "IMG_1.jpg", "7")
    check("a missing event is a failure, not retried", id == nil and #sent == 1, tostring(err))
    check("with the server's reason", err == "HTTP 404 - Event not found", tostring(err))
end

do
    local sent = serve({ { status = 404, body = { error = "No photo 7 in event 3" } } })
    local id = api:uploadPhoto(3, "/tmp/r/IMG_1.jpg", "IMG_1.jpg", nil)
    check("a plain upload's 404 is not retried", id == nil and #sent == 1)
end

do
    local sent = serve({ { status = 400, body = { error = "An image can only replace an image" } } })
    local id, err = api:uploadPhoto(3, "/tmp/r/IMG_1.jpg", "IMG_1.jpg", "7")
    check("a refused replace is not retried as new", id == nil and #sent == 1, tostring(err))
end

-- Render failures ----------------------------------------------------------------

local function rendition(fileName)
    return {
        photo = { getFormattedMetadata = function(_, key) if key == "fileName" then return fileName end end },
    }
end

do
    local list = {}
    util.recordRenderFailure(list, rendition("CLIP_1.MOV"), "codec not supported")
    check("a failed render is listed with its reason",
        #list == 1 and list[1] == "CLIP_1.MOV (render failed: codec not supported)", list[1])
end

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then os.exit(1) end
