require("PicPeakAPI")
require("MetadataTask")
require("SharedDialogSections")

PublishTask = {}

-- ---------------------------------------------------------------------------
-- Resolve or create the event for a publish collection.
-- ---------------------------------------------------------------------------
local function resolvePublishEvent(picpeak, exportContext)
    local publishedCollection = exportContext.publishedCollection
    local cs = publishedCollection:getCollectionInfoSummary().collectionSettings
    local strategy = cs.albumCreationStrategy or "collection"
    local eventId = publishedCollection:getRemoteId()
    local collectionName = publishedCollection:getName()
    local exportSession = exportContext.exportSession

    log:trace("resolvePublishEvent: strategy=" .. strategy .. " remoteId=" .. tostring(eventId))

    if strategy == "existing" and cs.remoteId then
        eventId = tostring(cs.remoteId)
    end

    if eventId and eventId ~= "" then
        if picpeak:checkIfEventExists(eventId) then
            local shareUrl = picpeak:getEventShareUrl(eventId)
            exportSession:recordRemoteCollectionId(eventId)
            if shareUrl then exportSession:recordRemoteCollectionUrl(shareUrl) end
            return eventId
        else
            log:warn("resolvePublishEvent: event " .. eventId .. " gone, creating new one")
            eventId = nil
        end
    end

    -- Build creation params from collection settings
    local newId, shareUrl = picpeak:createEvent({
        event_name          = collectionName,
        event_type          = cs.eventType,
        event_date          = cs.eventDate,
        customer_name       = cs.customerName,
        customer_email      = cs.customerEmail,
        customer_phone      = cs.customerPhone,
        admin_email         = cs.adminEmail,
        require_password    = cs.requirePassword,
        password            = cs.password,
        expires_at          = cs.expiresAt,
        feedback_enabled    = cs.feedbackEnabled,
        color_theme         = cs.colorTheme,
    })
    if not newId then
        ErrorHandler.handleError(
            "Failed to create PicPeak event for collection '" .. collectionName .. "'.",
            "resolvePublishEvent: createEvent returned nil"
        )
        return nil
    end
    newId = tostring(newId)
    exportSession:recordRemoteCollectionId(newId)
    if shareUrl then exportSession:recordRemoteCollectionUrl(shareUrl) end
    log:info("resolvePublishEvent: created event id=" .. newId)
    return newId
end

-- ---------------------------------------------------------------------------
-- Main publish entry point
-- ---------------------------------------------------------------------------

function PublishTask.processRenderedPhotos(functionContext, exportContext)
    local exportSession, exportParams, picpeak = util.validateExportContextAndConnect(exportContext, "Publish")
    if not exportSession then return nil end

    local eventId = resolvePublishEvent(picpeak, exportContext)
    if not eventId then return nil end

    local nPhotos = exportSession:countRenditions()
    local progressTitle = (exportParams.url ~= "") and exportParams.url or "PicPeak"
    log:info("=== PicPeak Publish START: " .. nPhotos .. " photos | eventId=" .. eventId .. " ===")

    local progressScope = LrProgressScope({
        title = util.buildSimpleUploadProgressTitle(nPhotos, "Publishing", progressTitle),
        functionContext = functionContext,
    })

    local failures = {}
    local replaced = 0
    local done = 0
    local shareUrl = picpeak:getEventShareUrl(eventId)

    for _, rendition in exportContext:renditions({ stopIfCanceled = true }) do
        local success, pathOrMessage = rendition:waitForRender()
        if progressScope:isCanceled() then break end

        if success then
            local photo = rendition.photo
            local fileName = util.uploadNameFor(photo, pathOrMessage)

            -- Detect re-publish: Lightroom passes an existing remote ID for photos
            -- that were previously published and have since been modified.
            --
            -- This used to SKIP the upload, because v1 had no way to replace a
            -- photo and a plain upload would have created a duplicate. It now
            -- has one (replaces_photo_id, PicPeak/picpeak#745), so a
            -- re-publish actually pushes the edited version — which is what
            -- "republish" always looked like it did. The photo keeps its id,
            -- its feedback and its position, so the client's proofing marks
            -- survive the update.
            --
            -- publishedPhotoId is the SDK's field for the id recorded by
            -- recordPublishedPhotoId on the last publish. This used to read
            -- rendition.publishedPhoto, which LrExportRendition does not have,
            -- so every re-publish uploaded a duplicate.
            local existingId = rendition.publishedPhotoId
            local replacesPhotoId = (existingId and existingId ~= "") and tostring(existingId) or nil

            local photoId, errReason, wasReplaced
            local unsupported = util.unsupportedVideoReason(photo, pathOrMessage)
            if unsupported then
                errReason = unsupported
            else
                photoId, errReason, wasReplaced = picpeak:uploadPhoto(
                    eventId, pathOrMessage, fileName, replacesPhotoId
                )
            end
            util.safeDeleteTempFile(pathOrMessage)

            if not photoId then
                log:error("PublishTask: upload failed for " .. fileName .. ": " .. tostring(errReason))
                local reason = unsupported or util.uploadFailureReason(photo, errReason)
                table.insert(failures, fileName .. " (" .. reason .. ")")
                -- Without this Lightroom files the photo under Published,
                -- and it would not be offered again on the next publish.
                rendition:uploadFailed(reason)
            else
                local photoIdStr = tostring(photoId)
                MetadataTask.setPhotoId(photo, photoIdStr)
                MetadataTask.setEventId(photo, eventId)
                rendition:recordPublishedPhotoId(photoIdStr)
                if shareUrl then rendition:recordPublishedPhotoUrl(shareUrl) end
                if wasReplaced then
                    replaced = replaced + 1
                end
                log:info("PublishTask: " .. fileName .. " -> photoId=" .. photoIdStr
                    .. (wasReplaced and " (replaced)" or ""))
            end
        else
            util.safeDeleteTempFile(pathOrMessage)
            util.recordRenderFailure(failures, rendition, pathOrMessage)
        end

        done = done + 1
        progressScope:setPortionComplete(done, nPhotos)
        if done == 1 or done % 10 == 0 or done == nPhotos then
            log:info("Publish progress: " .. done .. "/" .. nPhotos)
        end
    end

    progressScope:done()
    log:info("=== PicPeak Publish DONE: " .. nPhotos .. " | failures=" .. #failures
        .. " | replaced=" .. replaced .. " ===")
    -- The old "N photos were not re-uploaded" notice is gone with the skip it
    -- described: re-publishing now updates the photo in place. Replacements
    -- are reported in the log rather than a dialog, because a successful
    -- update is the expected outcome and does not need interrupting for.
    util.reportUploadFailures(failures)
end

-- ---------------------------------------------------------------------------
-- Collection management
-- ---------------------------------------------------------------------------

function PublishTask.deletePhotosFromPublishedCollection(publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId)
    if #arrayOfPhotoIds > 0 then
        LrDialogs.message(
            "PicPeak: Photos removed from collection",
            "The PicPeak API (v1) does not support deleting individual photos remotely. "
                .. tostring(#arrayOfPhotoIds)
                .. " photo(s) were removed from the Lightroom publish collection but remain in the PicPeak gallery. "
                .. "Delete them manually in PicPeak if needed.",
            "info"
        )
    end
    for _, photoId in ipairs(arrayOfPhotoIds) do deletedCallback(photoId) end
end

function PublishTask.deletePublishedCollection(publishSettings, info)
    if info.remoteId and info.remoteId ~= "" then
        LrDialogs.message(
            "PicPeak: Gallery not deleted",
            "The PicPeak API (v1) does not support deleting gallery events remotely. "
                .. "The Lightroom collection was removed, but the gallery (event id="
                .. tostring(info.remoteId)
                .. ") still exists in PicPeak. Delete it manually in the PicPeak admin interface.",
            "info"
        )
    end
end

function PublishTask.renamePublishedCollection(publishSettings, info)
    log:trace("renamePublishedCollection: rename not supported by PicPeak v1 API")
end

function PublishTask.shouldDeletePhotosFromServiceOnDeleteFromCatalog(publishSettings, nPhotos)
    return nil
end

function PublishTask.validatePublishedCollectionName(name)
    if util.nilOrEmpty(name) then
        return false, "Event name must not be empty."
    end
    return true, ""
end

function PublishTask.getCollectionBehaviorInfo(publishSettings)
    return {
        defaultCollectionName = "My Gallery",
        defaultCollectionCanBeDeleted = true,
        canAddCollection = true,
    }
end

-- ---------------------------------------------------------------------------
-- Per-collection settings dialog
-- ---------------------------------------------------------------------------

-- Helper: seed pluginContext from persisted collectionSettings (for re-opens)
local function seedPluginContext(ctx, cs)
    ctx.albumCreationStrategy = cs.albumCreationStrategy or "collection"
    ctx.eventType             = cs.eventType or "other"
    ctx.eventDate             = cs.eventDate or ""
    ctx.customerName          = cs.customerName or ""
    ctx.customerEmail         = cs.customerEmail or ""
    ctx.customerPhone         = cs.customerPhone or ""
    ctx.adminEmail            = cs.adminEmail or ""
    ctx.requirePassword       = cs.requirePassword or false
    ctx.password              = cs.password or ""
    ctx.expiresAt             = cs.expiresAt or ""
    ctx.feedbackEnabled       = cs.feedbackEnabled or false
    ctx.colorTheme            = cs.colorTheme or ""
    ctx.selectedEventId       = cs.remoteId or "0"
    ctx.picpeakEvents         = { { title = "Loading…", value = "0" } }
end

function PublishTask.viewForCollectionSettings(f, publishSettings, info)
    -- Existing published collection: show read-only summary
    if info.publishedCollection ~= nil then
        local remoteId = info.publishedCollection:getRemoteId()
        local name = info.publishedCollection:getName()
        local rows = {}
        if remoteId then
            table.insert(rows, f:row({
                f:static_text({ title = "PicPeak event ID: ", font = "<system/small>" }),
                f:static_text({ title = tostring(remoteId), font = "<system/bold/small>" }),
            }))
        end
        if name then
            table.insert(rows, f:row({
                f:static_text({ title = "Collection name: ", font = "<system/small>" }),
                f:static_text({ title = tostring(name), font = "<system/small>" }),
            }))
        end
        if #rows == 0 then table.insert(rows, f:row({})) end
        return f:column(rows)
    end

    -- New collection: seed context and build form
    local ctx = info.pluginContext
    local cs = info.collectionSettings or {}
    seedPluginContext(ctx, cs)

    -- Async: load event list for "use existing" picker
    LrTasks.startAsyncTask(function()
        local picpeak = PicPeakAPI:new(publishSettings.url, publishSettings.apiToken)
        local events = picpeak:getEvents()
        local items = { { title = "Please select", value = "0" } }
        for _, e in ipairs(events or {}) do table.insert(items, e) end
        ctx.picpeakEvents = items
    end)

    local bind = LrView.bind
    local lw = LrView.share("cs_lw")

    return f:group_box({
        bind_to_object = ctx,
        title = "PicPeak Event Settings",
        fill_horizontal = 1,
        f:column({
            spacing = f:control_spacing(),
            fill_horizontal = 1,

            -- Strategy
            f:radio_button({
                title = "Create new event from collection name",
                checked_value = "collection",
                value = bind("albumCreationStrategy"),
            }),
            f:row({
                f:radio_button({
                    title = "Use existing event",
                    checked_value = "existing",
                    value = bind("albumCreationStrategy"),
                }),
                f:popup_menu({
                    items = bind("picpeakEvents"),
                    value = bind("selectedEventId"),
                    width_in_chars = 28,
                    enabled = bind({
                        key = "albumCreationStrategy",
                        object = ctx,
                        transform = function(value) return value == "existing" end,
                    }),
                    immediate = true,
                }),
            }),

            f:separator({ fill_horizontal = 1 }),

            -- New event details (shown when strategy == "collection")
            f:column({
                visible = bind({
                    key = "albumCreationStrategy",
                    object = ctx,
                    transform = function(value) return value == "collection" end,
                }),
                spacing = f:control_spacing(),
                fill_horizontal = 1,

                f:group_box({
                    title = "Event Details",
                    fill_horizontal = 1,
                    f:column({
                        spacing = f:control_spacing(),
                        fill_horizontal = 1,
                        f:row({
                            f:static_text({ title = "Event type:", alignment = "right", width = lw }),
                            f:popup_menu({
                                value = bind("eventType"),
                                items = SharedDialogSections.EVENT_TYPES,
                                immediate = true,
                            }),
                        }),
                        f:row({
                            f:static_text({ title = "Event date:", alignment = "right", width = lw }),
                            f:edit_field({ value = bind("eventDate"), width_in_chars = 14, immediate = true }),
                            f:static_text({ title = "YYYY-MM-DD, optional", font = "<system/small>" }),
                        }),
                    }),
                }),

                f:group_box({
                    title = "Customer Information",
                    fill_horizontal = 1,
                    f:column({
                        spacing = f:control_spacing(),
                        fill_horizontal = 1,
                        f:row({
                            f:static_text({ title = "Customer name:", alignment = "right", width = lw }),
                            f:edit_field({ value = bind("customerName"), fill_horizontal = 1, immediate = true }),
                        }),
                        f:row({
                            f:static_text({ title = "Customer email:", alignment = "right", width = lw }),
                            f:edit_field({ value = bind("customerEmail"), fill_horizontal = 1, immediate = true }),
                        }),
                        f:row({
                            f:static_text({ title = "Customer phone:", alignment = "right", width = lw }),
                            f:edit_field({ value = bind("customerPhone"), fill_horizontal = 1, immediate = true }),
                            f:static_text({ title = "optional", font = "<system/small>" }),
                        }),
                        f:row({
                            f:static_text({ title = "Admin email:", alignment = "right", width = lw }),
                            f:edit_field({ value = bind("adminEmail"), fill_horizontal = 1, immediate = true }),
                            f:static_text({ title = "for notifications", font = "<system/small>" }),
                        }),
                    }),
                }),

                f:group_box({
                    title = "Access & Expiry",
                    fill_horizontal = 1,
                    f:column({
                        spacing = f:control_spacing(),
                        fill_horizontal = 1,
                        f:row({
                            f:static_text({ title = "Password protect:", alignment = "right", width = lw }),
                            f:checkbox({
                                title = "Require password to view gallery",
                                value = bind("requirePassword"),
                            }),
                        }),
                        f:row({
                            visible = bind("requirePassword"),
                            f:static_text({ title = "Gallery password:", alignment = "right", width = lw }),
                            f:password_field({ value = bind("password"), fill_horizontal = 1, immediate = true }),
                        }),
                        f:row({
                            f:static_text({ title = "Expires at:", alignment = "right", width = lw }),
                            f:edit_field({ value = bind("expiresAt"), width_in_chars = 22, immediate = true }),
                            f:static_text({ title = "YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS", font = "<system/small>" }),
                        }),
                    }),
                }),

                f:group_box({
                    title = "Gallery Options",
                    fill_horizontal = 1,
                    f:column({
                        spacing = f:control_spacing(),
                        fill_horizontal = 1,
                        f:row({
                            f:static_text({ title = "Guest feedback:", alignment = "right", width = lw }),
                            f:checkbox({
                                title = "Enable ratings, likes, comments & favorites",
                                value = bind("feedbackEnabled"),
                            }),
                        }),
                        f:row({
                            f:static_text({ title = "Color theme:", alignment = "right", width = lw }),
                            f:edit_field({ value = bind("colorTheme"), width_in_chars = 20, immediate = true }),
                            f:static_text({ title = "PicPeak preset name, optional", font = "<system/small>" }),
                        }),
                    }),
                }),
            }),
        }),
    })
end

function PublishTask.endDialogForCollectionSettings(publishSettings, info)
    log:trace("endDialogForCollectionSettings")
    if info.why ~= "ok" then return end

    local ctx = info.pluginContext
    local cs = info.collectionSettings

    cs.albumCreationStrategy = ctx.albumCreationStrategy or "collection"

    if cs.albumCreationStrategy == "existing" then
        local sel = ctx.selectedEventId
        if util.nilOrEmpty(sel) or sel == "0" then
            ErrorHandler.handleError("No event selected.", "endDialogForCollectionSettings: no event selected")
            return
        end
        cs.remoteId = sel
    else
        -- Persist all "new event" creation params into collection settings
        cs.eventType        = ctx.eventType
        cs.eventDate        = ctx.eventDate
        cs.customerName     = ctx.customerName
        cs.customerEmail    = ctx.customerEmail
        cs.customerPhone    = ctx.customerPhone
        cs.adminEmail       = ctx.adminEmail
        cs.requirePassword  = ctx.requirePassword
        cs.password         = ctx.password
        cs.expiresAt        = ctx.expiresAt
        cs.feedbackEnabled  = ctx.feedbackEnabled
        cs.colorTheme       = ctx.colorTheme
    end
end

function PublishTask.updateCollectionSettings(publishSettings, info)
    log:trace("updateCollectionSettings")
    if not info or not info.collectionSettings then return end
    local cs = info.collectionSettings
    if cs.albumCreationStrategy == "existing" and cs.remoteId then
        local picpeak = PicPeakAPI:new(publishSettings.url, publishSettings.apiToken)
        if not picpeak:checkConnectivity() then
            log:warn("updateCollectionSettings: PicPeak not reachable")
            return
        end
        local eventId = tostring(cs.remoteId)
        local name = picpeak:getEventName(eventId) or ("Event " .. eventId)
        local shareUrl = picpeak:getEventShareUrl(eventId)
        log:trace("updateCollectionSettings: binding event id=" .. eventId .. " name=" .. name)
        local catalog = LrApplication.activeCatalog()
        if catalog and info.publishedCollection then
            catalog:withWriteAccessDo("Bind PicPeak event", function()
                info.publishedCollection:setRemoteId(eventId)
                if shareUrl then info.publishedCollection:setRemoteUrl(shareUrl) end
                info.publishedCollection:setName(name)
            end)
        end
    end
end
