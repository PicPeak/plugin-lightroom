-- Helper functions

util = {}

function util.table_contains(tbl, x)
    if type(tbl) ~= "table" then
        return false
    end
    local found = false
    for _, v in pairs(tbl) do
        if v == x then
            found = true
            break
        end
    end
    return found
end

function util.dumpTable(t)
    if t == nil then
        return "nil"
    end
    local ok, s = LrTasks.pcall(function()
        return inspect(t)
    end)
    if not ok or s == nil then
        return tostring(t)
    end
    local pattern = '(field = "Authorization",%s+value = "[Bb]earer %w%w%w%w%w%w%w%w%w%w%w)(%w+)(")'
    return s:gsub(pattern, "%1...%3")
end

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

function util.nilOrEmpty(val)
    if type(val) == "string" then
        return val == nil or trim(val) == ""
    else
        return val == nil
    end
end

function util.getExtension(path)
    if not path or type(path) ~= "string" then
        return ""
    end
    return string.lower(string.match(path, "%.([^%.]+)$") or "")
end

function util.cutToken(key)
    if key == nil or type(key) ~= "string" then
        return "(no token)"
    end
    if key == "" then
        return "(empty token)"
    end
    if #key <= 20 then
        return string.sub(key, 1, 8) .. "..."
    end
    return string.sub(key, 1, 20) .. "..."
end

function util.getLogfilePath()
    local filename = "PicPeakPlugin.log"
    local macPath14 = LrPathUtils.getStandardFilePath("home") .. "/Library/Logs/Adobe/Lightroom/LrClassicLogs/"
    local winPath14 = LrPathUtils.getStandardFilePath("home")
        .. "\\AppData\\Local\\Adobe\\Lightroom\\Logs\\LrClassicLogs\\"
    local macPathOld = LrPathUtils.getStandardFilePath("documents") .. "/LrClassicLogs/"
    local winPathOld = LrPathUtils.getStandardFilePath("documents") .. "\\LrClassicLogs\\"

    local lightroomVersion = LrApplication.versionTable()

    if lightroomVersion.major >= 14 then
        if MAC_ENV then
            return macPath14 .. filename
        else
            return winPath14 .. filename
        end
    else
        if MAC_ENV then
            return macPathOld .. filename
        else
            return winPathOld .. filename
        end
    end
end

function util.getPhotoDeviceId(photo)
    if not photo then
        return nil
    end
    local uuid = photo:getRawMetadata("uuid")
    if uuid and uuid ~= "" then
        return tostring(uuid)
    end
    if photo.localIdentifier then
        return tostring(photo.localIdentifier)
    end
    return nil
end

-- Shared: validate export context and connect to PicPeak.
function util.validateExportContextAndConnect(exportContext, contextLabel)
    if not exportContext or not exportContext.exportSession or not exportContext.propertyTable then
        ErrorHandler.handleError(
            "Export context is missing. Please try again.",
            (contextLabel or "Export") .. "Task: invalid export context"
        )
        return nil
    end
    local exportSession = exportContext.exportSession
    local exportParams = exportContext.propertyTable
    local settingsText = (contextLabel == "Publish") and "plugin settings" or "export settings"
    if util.nilOrEmpty(exportParams.url) or util.nilOrEmpty(exportParams.apiToken) then
        ErrorHandler.handleError(
            "Configure PicPeak URL and API token in the " .. settingsText .. ".",
            (contextLabel or "Export") .. "Task: URL or API token not set"
        )
        return nil
    end
    local picpeak = PicPeakAPI:new(exportParams.url, exportParams.apiToken)
    if not picpeak:checkConnectivity() then
        ErrorHandler.handleError(
            "PicPeak connection not working. Check URL and API token in " .. settingsText .. ".",
            "PicPeak connection not working. Export stopped."
        )
        return nil
    end
    return exportSession, exportParams, picpeak
end

function util.buildSimpleUploadProgressTitle(nPhotos, verb, suffix)
    local countStr = (nPhotos > 1) and (nPhotos .. " photos") or "one photo"
    return verb .. " " .. countStr .. " to " .. (suffix or "PicPeak")
end

function util.reportUploadFailures(failures)
    if failures and #failures > 0 then
        local message = (#failures == 1) and "1 file failed to upload correctly."
            or (tostring(#failures) .. " files failed to upload correctly.")
        local formattedFailures = {}
        for i = 1, math.min(#failures, 20) do
            table.insert(formattedFailures, "• " .. failures[i])
        end
        if #failures > 20 then
            table.insert(formattedFailures, "... and " .. tostring(#failures - 20) .. " more failures.")
            table.insert(formattedFailures, "(Check PicPeakPlugin.log for full details)")
        end
        LrDialogs.message(message, table.concat(formattedFailures, "\n"), "critical")
    end
end

-- Safe delete of a rendered temp file (no-op if path is nil or file doesn't exist).
function util.safeDeleteTempFile(path)
    if not path or path == "" then
        return
    end
    local ok, err = LrTasks.pcall(function()
        LrFileUtils.delete(path)
    end)
    if not ok then
        log:warn("safeDeleteTempFile: could not delete " .. tostring(path) .. ": " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Filename matching for the round-trip (PicPeak/picpeak#745)
-- ---------------------------------------------------------------------------

-- Extensions worth indexing when scanning a RAW folder. JPEG/HEIC are in the
-- list on purpose: plenty of photographers deliver from JPEG masters, and a
-- folder with no RAW at all should still match rather than silently find zero.
util.RAW_EXTENSIONS = {
    "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "dng", "pef", "srw",
    "srf", "sr2", "3fr", "fff", "iiq", "erf", "mos", "mrw", "x3f", "gpr",
    "jpg", "jpeg", "heic", "heif", "tif", "tiff", "png",
}

-- The filename without its extension: "IMG_1234.CR3" -> "IMG_1234"
function util.stemOf(filename)
    if util.nilOrEmpty(filename) then
        return nil
    end
    local name = tostring(filename):gsub("^.*[/\\]", "")
    return (name:gsub("%.[^.]+$", ""))
end

-- The lowercase extension without the dot, or nil.
function util.extensionOf(filename)
    if util.nilOrEmpty(filename) then
        return nil
    end
    local ext = tostring(filename):match("%.([^.]+)$")
    return ext and ext:lower() or nil
end

--[[
    The name a render is uploaded under. A photo keeps its catalog name: the
    round-trip matches on it. A video takes the rendered file's extension,
    because the export can transcode an .MOV to an H.264 .mp4 and PicPeak names
    the stored file from what it is told. The stem is kept either way.
]]
function util.uploadNameFor(photo, renderedPath)
    local fileName = photo:getFormattedMetadata("fileName")
    if not photo:getRawMetadata("isVideo") then
        return fileName
    end
    local stem, ext = util.stemOf(fileName), util.extensionOf(renderedPath)
    if not stem or not ext then
        return fileName
    end
    return stem .. "." .. ext
end

-- A refused video most often means the server cannot take one yet; say what
-- to change instead of leaving only the HTTP status.
function util.uploadFailureReason(photo, errReason)
    local reason = errReason or "Upload failed"
    if photo:getRawMetadata("isVideo") then
        reason = reason .. "; videos need a PicPeak version that accepts them over the API,"
            .. " with the video file type enabled in PicPeak's upload settings"
    end
    return reason
end

function util.isSupportedPhotoExtension(filename)
    local ext = util.extensionOf(filename)
    if not ext then
        return false
    end
    return util.table_contains(util.RAW_EXTENSIONS, ext)
end

-- The LONGEST trailing digit run of a filename stem:
--   "IMG_1234.JPG"            -> "1234"
--   "Smith_Wedding_11234.jpg" -> "11234"
--
-- Deliberately the longest run and never a fixed last-N slice. Multi-camera
-- shoots disambiguate by prefixing the camera index INTO the number
-- ("cam11234.jpg" / "cam21234.jpg"); a last-4 slice reads "1234" from both
-- bodies and reintroduces exactly the collision the prefix removes.
--
-- Must stay identical to trailingDigitRun() in the picpeak backend
-- (services/photoReplacementService.js) — update both together.
function util.trailingDigitRun(filename)
    local stem = util.stemOf(filename)
    if not stem then
        return nil
    end
    return stem:match("(%d+)$")
end

-- Case-insensitive stem, for building the folder index.
function util.normalizedStem(filename)
    local stem = util.stemOf(filename)
    return stem and stem:lower() or nil
end
