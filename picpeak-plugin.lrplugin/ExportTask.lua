require("PicPeakAPI")
require("MetadataTask")
require("SharedDialogSections")

ExportTask = {}

-- ---------------------------------------------------------------------------
-- Show "choose event" modal when eventMode is 'onexport'
-- ---------------------------------------------------------------------------
local function showEventOptionsDialog(picpeak, exportParams)
    local result = LrFunctionContext.callWithContext("eventChooser", function(context)
        local f = LrView.osFactory()
        exportParams.eventMode = "none"
        exportParams.events = picpeak:getEvents() or {}

        local dialogContent = f:column({
            bind_to_object = exportParams,
            spacing = f:control_spacing(),

            f:group_box({
                title = "PicPeak Gallery Event",
                fill_horizontal = 1,
                f:column({
                    spacing = f:control_spacing(),
                    fill_horizontal = 1,
                    margin_top = 5,
                    margin_bottom = 5,

                    f:static_text({
                        title = "Select the event (gallery) to upload photos to.",
                        alignment = "left",
                        font = "<system/small>",
                        fill_horizontal = 1,
                    }),

                    f:separator({ fill_horizontal = 1 }),

                    f:row({
                        f:static_text({
                            title = "Event mode:",
                            alignment = "right",
                            width = LrView.share("label_width"),
                        }),
                        f:popup_menu({
                            fill_horizontal = 1,
                            items = {
                                { title = "Do not use an event", value = "none" },
                                { title = "Existing event", value = "existing" },
                                { title = "Create new event", value = "new" },
                            },
                            value = LrView.bind("eventMode"),
                            immediate = true,
                        }),
                    }),

                    -- Existing picker
                    f:row({
                        visible = LrView.bind({
                            key = "eventMode",
                            object = exportParams,
                            transform = function(value) return value == "existing" end,
                        }),
                        f:static_text({
                            title = "Event:",
                            alignment = "right",
                            width = LrView.share("label_width"),
                        }),
                        f:popup_menu({
                            fill_horizontal = 1,
                            value = LrView.bind("eventId"),
                            items = LrView.bind("events"),
                            immediate = true,
                        }),
                    }),

                    -- New event fields
                    f:column({
                        visible = LrView.bind({
                            key = "eventMode",
                            object = exportParams,
                            transform = function(value) return value == "new" end,
                        }),
                        spacing = f:control_spacing(),
                        fill_horizontal = 1,
                        f:row({
                            f:static_text({ title = "Event name:", alignment = "right", width = LrView.share("label_width") }),
                            f:edit_field({ fill_horizontal = 1, value = LrView.bind("newEventName"), immediate = true }),
                        }),
                        f:row({
                            f:static_text({ title = "Event type:", alignment = "right", width = LrView.share("label_width") }),
                            f:popup_menu({
                                value = LrView.bind("newEventType"),
                                items = SharedDialogSections.EVENT_TYPES,
                                immediate = true,
                            }),
                        }),
                        f:row({
                            f:static_text({ title = "Customer name:", alignment = "right", width = LrView.share("label_width") }),
                            f:edit_field({ fill_horizontal = 1, value = LrView.bind("newEventCustomerName"), immediate = true }),
                        }),
                        f:row({
                            f:static_text({ title = "Customer email:", alignment = "right", width = LrView.share("label_width") }),
                            f:edit_field({ fill_horizontal = 1, value = LrView.bind("newEventCustomerEmail"), immediate = true }),
                        }),
                        f:row({
                            f:static_text({ title = "Password protect:", alignment = "right", width = LrView.share("label_width") }),
                            f:checkbox({ title = "Require password", value = LrView.bind("newEventRequirePassword") }),
                        }),
                        f:row({
                            visible = LrView.bind("newEventRequirePassword"),
                            f:static_text({ title = "Password:", alignment = "right", width = LrView.share("label_width") }),
                            f:password_field({ fill_horizontal = 1, value = LrView.bind("newEventPassword"), immediate = true }),
                        }),
                    }),
                }),
            }),
        })

        local dialogResult = LrDialogs.presentModalDialog({
            title = "PicPeak event options",
            contents = dialogContent,
        })

        if dialogResult ~= "ok" then
            LrDialogs.message("Export canceled.")
            return false
        end
        return true
    end, exportParams)

    return result == true
end

-- ---------------------------------------------------------------------------
-- Resolve event for export
-- ---------------------------------------------------------------------------
local function resolveEventForExport(picpeak, exportParams)
    if exportParams.eventMode == "onexport" then
        if not showEventOptionsDialog(picpeak, exportParams) then
            return true, nil  -- canceled
        end
    end

    if exportParams.eventMode == "existing" then
        local id = exportParams.eventId
        if util.nilOrEmpty(id) then
            log:warn("ExportTask: no event selected")
            return false, nil
        end
        log:trace("ExportTask: using existing event id=" .. tostring(id))
        return false, tostring(id)

    elseif exportParams.eventMode == "new" then
        local name = exportParams.newEventName
        if util.nilOrEmpty(name) then
            ErrorHandler.handleError(
                "Event name is required when creating a new event.",
                "ExportTask: newEventName empty"
            )
            return true, nil  -- treat as canceled / error
        end
        log:trace("ExportTask: creating new event '" .. name .. "'")
        local newId = picpeak:createEvent({
            event_name          = name,
            event_type          = exportParams.newEventType,
            event_date          = exportParams.newEventDate,
            customer_name       = exportParams.newEventCustomerName,
            customer_email      = exportParams.newEventCustomerEmail,
            customer_phone      = exportParams.newEventCustomerPhone,
            admin_email         = exportParams.newEventAdminEmail,
            require_password    = exportParams.newEventRequirePassword,
            password            = exportParams.newEventPassword,
            expires_at          = exportParams.newEventExpiresAt,
            feedback_enabled    = exportParams.newEventFeedbackEnabled,
            color_theme         = exportParams.newEventColorTheme,
        })
        if not newId then
            ErrorHandler.handleError(
                "Failed to create PicPeak event. Check connection and logs.",
                "ExportTask: createEvent returned nil"
            )
            return true, nil
        end
        log:info("ExportTask: created event id=" .. tostring(newId))
        return false, tostring(newId)

    elseif exportParams.eventMode == "none" then
        log:trace("ExportTask: no event mode, uploading without event association")
        return false, nil
    end

    log:warn("ExportTask: unknown eventMode=" .. tostring(exportParams.eventMode))
    return false, nil
end

-- ---------------------------------------------------------------------------
-- Main export entry point
-- ---------------------------------------------------------------------------

function ExportTask.processRenderedPhotos(functionContext, exportContext)
    local exportSession, exportParams, picpeak = util.validateExportContextAndConnect(exportContext, "Export")
    if not exportSession then
        return nil
    end

    local nPhotos = exportSession:countRenditions()
    log:info("=== PicPeak Export START: " .. nPhotos .. " photos | url=" .. tostring(exportParams.url)
        .. " | eventMode=" .. tostring(exportParams.eventMode) .. " ===")

    local canceled, eventId = resolveEventForExport(picpeak, exportParams)
    if canceled then
        return
    end

    local progressScope = LrProgressScope({
        title = util.buildSimpleUploadProgressTitle(nPhotos, "Exporting", exportParams.url or "PicPeak"),
        functionContext = functionContext,
    })

    local failures = {}
    local atLeastOneSuccess = false
    local done = 0

    for _, rendition in exportContext:renditions({ stopIfCanceled = true }) do
        local success, pathOrMessage = rendition:waitForRender()
        if progressScope:isCanceled() then
            break
        end

        -- waitForRender answers true for a skipped rendition but renders no
        -- file, so check before treating it as a render to upload.
        if rendition.wasSkipped then
            log:info("ExportTask: rendition skipped")
        elseif success then
            local photo = rendition.photo
            local fileName = util.uploadNameFor(photo, pathOrMessage)

            -- If this photo came FROM PicPeak (imported by the round-trip),
            -- put the finished render back over its proof instead of adding a
            -- second copy (#745). The id lives in plugin metadata, so it
            -- survives the editor renaming the file — which is exactly the
            -- case filename matching cannot handle.
            --
            -- Only when the stored event matches the export target: exporting
            -- to a DIFFERENT gallery is a new photo there, not a replacement.
            local replacesPhotoId = nil
            local storedEventId = MetadataTask.getEventId(photo)
            if storedEventId and tostring(storedEventId) == tostring(eventId) then
                replacesPhotoId = MetadataTask.getPhotoId(photo)
            end

            local photoId, errReason
            local unsupported = util.unsupportedVideoReason(photo, pathOrMessage)
            if unsupported then
                errReason = unsupported
            else
                photoId, errReason = picpeak:uploadPhoto(
                    eventId, pathOrMessage, fileName, replacesPhotoId
                )
            end
            util.safeDeleteTempFile(pathOrMessage)

            if not photoId then
                log:error("ExportTask: upload failed for " .. fileName .. ": " .. tostring(errReason))
                table.insert(failures, fileName .. " (" .. (unsupported or util.uploadFailureReason(photo, errReason)) .. ")")
            else
                atLeastOneSuccess = true
                MetadataTask.setPhotoId(photo, tostring(photoId))
                if eventId then
                    MetadataTask.setEventId(photo, eventId)
                end
                log:info("ExportTask: uploaded " .. fileName .. " -> photoId=" .. tostring(photoId))
            end
        else
            log:warn("ExportTask: render failed for photo: " .. tostring(pathOrMessage))
            util.safeDeleteTempFile(pathOrMessage)
            util.recordRenderFailure(failures, rendition, pathOrMessage)
        end

        done = done + 1
        progressScope:setPortionComplete(done, nPhotos)
        if done == 1 or done % 10 == 0 or done == nPhotos then
            log:info("Export progress: " .. done .. "/" .. nPhotos)
        end
    end

    progressScope:done()

    -- If we created a new event but nothing uploaded, it will remain as an empty gallery.
    -- PicPeak v1 API has no delete event endpoint, so we just warn.
    if not atLeastOneSuccess and exportParams.eventMode == "new" and eventId then
        LrDialogs.message(
            "PicPeak Export",
            "No photos were uploaded successfully. The empty gallery event was left on the server.",
            "warning"
        )
    end

    log:info("=== PicPeak Export DONE: " .. nPhotos .. " photos | failures=" .. #failures .. " ===")
    util.reportUploadFailures(failures)

    -- Show share link if we have an event
    if atLeastOneSuccess and eventId then
        local shareUrl = picpeak:getEventShareUrl(eventId)
        if shareUrl then
            local result = LrDialogs.confirm(
                "Upload complete",
                "Gallery share link:\n" .. shareUrl,
                "Copy to clipboard",
                "Close"
            )
            if result == "ok" then
                LrDialogs.message("Copied!", shareUrl)
            end
        end
    end
end
