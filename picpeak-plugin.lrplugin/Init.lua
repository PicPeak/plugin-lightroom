---@diagnostic disable: undefined-global

-- Global imports
_G.LrHttp = import("LrHttp")
_G.LrDate = import("LrDate")
_G.LrPathUtils = import("LrPathUtils")
_G.LrFileUtils = import("LrFileUtils")
_G.LrTasks = import("LrTasks")
_G.LrErrors = import("LrErrors")
_G.LrDialogs = import("LrDialogs")
_G.LrView = import("LrView")
_G.LrBinding = import("LrBinding")
_G.LrColor = import("LrColor")
_G.LrFunctionContext = import("LrFunctionContext")
_G.LrApplication = import("LrApplication")
_G.LrPrefs = import("LrPrefs")
_G.LrShell = import("LrShell")
_G.LrSystemInfo = import("LrSystemInfo")
_G.LrPasswords = import("LrPasswords")
_G.LrProgressScope = import("LrProgressScope")
_G.LrLogger = import("LrLogger")

_G.JSON = require("JSON")
_G.inspect = require("inspect")
require("util")
require("ErrorHandler")
require("TokenStore")
require("ServerStore")

-- Global initializations
_G.prefs = _G.LrPrefs.prefsForPlugin()
_G.log = import("LrLogger")("PicPeakPlugin")
if _G.prefs.logging == nil then
    _G.prefs.logging = false
end
if _G.prefs.logging then
    _G.log:enable("logfile")
else
    _G.log:disable()
end

if _G.prefs.apiToken == nil then
    _G.prefs.apiToken = ""
end
if _G.prefs.url == nil then
    _G.prefs.url = ""
end

-- Sign-in state (#745). The token itself now lives in the OS keychain via
-- TokenStore; prefs.apiToken remains only as the migration source for
-- installs that predate that, and is cleared once moved. These keys only
-- describe HOW the token got there.
--
-- apiTokenId is stored so "sign out and revoke" can delete the right token:
-- the admin routes are JWT-only, so the token cannot identify itself.
if _G.prefs.apiTokenId == nil then
    _G.prefs.apiTokenId = nil
end
if _G.prefs.signedInAs == nil then
    _G.prefs.signedInAs = ""
end
if _G.prefs.tokenExpiresAt == nil then
    _G.prefs.tokenExpiresAt = ""
end
if _G.prefs.showAdvanced == nil then
    _G.prefs.showAdvanced = false
end
-- Known servers, JSON-encoded (ServerStore). The ACTIVE one stays in
-- prefs.url so an install predating multi-server support keeps working.
if _G.prefs.serverList == nil then
    _G.prefs.serverList = ""
end
