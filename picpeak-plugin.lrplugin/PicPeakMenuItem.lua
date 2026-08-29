--[[
    Library > Plug-in Extras > PicPeak Overview

    The plugin's single entry point. Opens the overview, which dispatches to
    the importer and the connection screen.

    **There is no keyboard shortcut, and none is possible.** Lightroom's SDK
    cannot bind one, and a macOS App Shortcut cannot reach these items either:
    Lightroom builds the Plug-in Extras entries lazily when the menu is opened,
    after macOS has already applied key equivalents at launch, so the binding
    lands on the disabled plugin-name header and never on the item. Verified
    against a real install — do not re-litigate without testing it in the menu.

    Dispatch is by return value, never by nesting modal dialogs: the overview
    closes, the chosen flow runs, the overview comes back.
]]

require("PicPeakOverview")
require("ImportSelectionsDialog")
require("ConnectionDialog")

LrTasks.startAsyncTask(function()
    local ok, err = LrTasks.pcall(function()
        -- Bounded rather than `while true`: every pass is a real user
        -- decision, but a bug that always returned the same action would
        -- otherwise spin dialogs with no way out.
        for _ = 1, 50 do
            local choice = PicPeakOverview.show()
            if choice == nil then
                return
            elseif choice == "config" then
                ConnectionDialog.show()
            elseif choice == "import" then
                -- The importer asks for the connection screen when the server
                -- is unconfigured or its token has stopped working.
                if ImportSelectionsDialog.show() == "connection" then
                    ConnectionDialog.show()
                end
            end
        end
    end)
    if not ok then
        log:error("PicPeakMenuItem failed: " .. tostring(err))
        ErrorHandler.handleError(
            "Something went wrong opening PicPeak. See the plug-in log for details.",
            "PicPeakMenuItem: " .. tostring(err)
        )
    end
end)
