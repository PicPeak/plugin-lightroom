--[[
    Upload naming for photos and videos (issue 8).

    A photo is uploaded under its catalog name, which the round-trip matches
    on. A video takes the rendered file's extension, so an .MOV exported as an
    H.264 .mp4 is not stored on PicPeak as .MOV.

    Run from the repository root with any Lua 5.1+ interpreter:

        lua tests/upload_name_test.lua
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

dofile("picpeak-plugin.lrplugin/util.lua")

local function fakePhoto(fileName, isVideo)
    return {
        getFormattedMetadata = function(_, key)
            if key == "fileName" then return fileName end
        end,
        getRawMetadata = function(_, key)
            if key == "isVideo" then return isVideo end
        end,
    }
end

local photo = fakePhoto("IMG_1234.CR3", false)
check("a photo keeps its catalog name", util.uploadNameFor(photo, "/tmp/render/IMG_1234.jpg") == "IMG_1234.CR3")

local mov = fakePhoto("CLIP_0001.MOV", true)
check("a transcoded video takes the rendered extension",
    util.uploadNameFor(mov, "/tmp/render/CLIP_0001.mp4") == "CLIP_0001.mp4",
    util.uploadNameFor(mov, "/tmp/render/CLIP_0001.mp4"))
check("an original video keeps its own extension, lower-cased from the render",
    util.uploadNameFor(mov, "/tmp/render/CLIP_0001.MOV") == "CLIP_0001.mov")
check("a render without an extension leaves the catalog name",
    util.uploadNameFor(mov, "/tmp/render/CLIP_0001") == "CLIP_0001.MOV")

check("a refused photo keeps the server's reason",
    util.uploadFailureReason(photo, "HTTP 400 - Invalid image file") == "HTTP 400 - Invalid image file")
check("a refused video says what to enable",
    util.uploadFailureReason(mov, "HTTP 400 - Only image uploads are accepted on this endpoint")
        :find("video file type enabled", 1, true) ~= nil)
check("a failure without a reason still reads",
    util.uploadFailureReason(photo, nil) == "Upload failed")

check("a photo is never held to the video formats",
    util.unsupportedVideoReason(photo, "/tmp/render/IMG_1234.jpg") == nil)
check("an H.264 render is uploadable", util.unsupportedVideoReason(mov, "/tmp/render/CLIP_0001.mp4") == nil)
check("an original .MOV is uploadable", util.unsupportedVideoReason(mov, "/tmp/render/CLIP_0001.MOV") == nil)
local mts = fakePhoto("00012.MTS", true)
local reason = util.unsupportedVideoReason(mts, "/tmp/render/00012.MTS")
check("an original .MTS is refused before the upload, naming the fix",
    reason ~= nil and reason:find(".mts", 1, true) ~= nil and reason:find("H.264", 1, true) ~= nil, reason)
check("a video render without an extension is refused",
    util.unsupportedVideoReason(mov, "/tmp/render/CLIP_0001") ~= nil)

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then os.exit(1) end
