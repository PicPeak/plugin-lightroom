--[[
    Library > Plug-in Extras > PicPeak Importer

    Straight to the importer, skipping the overview. The overview is the
    landing page for "where am I connected, what can I do"; this is for the
    case you already know — the repeat import, which is most of them.

    Same non-nesting rule as everywhere else: when the importer reports that
    the connection needs attention, it RETURNS and this opens the connection
    screen afterwards rather than stacking a modal inside a modal.
]]

require("ImportSelectionsDialog")
require("ConnectionDialog")

LrTasks.startAsyncTask(function()
    local ok, err = LrTasks.pcall(function()
        if ImportSelectionsDialog.show() == "connection" then
            ConnectionDialog.show()
            -- Back to the importer once, so fixing the connection lands you
            -- where you were going instead of at a dismissed dialog.
            ImportSelectionsDialog.show()
        end
    end)
    if not ok then
        log:error("PicPeakImportMenuItem failed: " .. tostring(err))
        ErrorHandler.handleError(
            "Something went wrong opening the PicPeak importer. See the plug-in log for details.",
            "PicPeakImportMenuItem: " .. tostring(err)
        )
    end
end)
