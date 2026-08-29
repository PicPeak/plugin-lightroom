return {

    LrSdkVersion = 3.0,
    LrSdkMinimumVersion = 3.0,

    LrToolkitIdentifier = "lrc-picpeak-plugin",

    LrPluginName = "PicPeak",

    LrInitPlugin = "Init.lua",

    LrExportServiceProvider = {
        {
            title = "PicPeak Exporter",
            file = "ExportServiceProvider.lua",
        },
        {
            title = "PicPeak Publisher",
            file = "PublishServiceProvider.lua",
        },
    },

    -- Library > Plug-in Extras. ONE entry, deliberately.
    --
    -- Lightroom Classic has no API for a top-level menu and none for a panel;
    -- File/Library > Plug-in Extras are the only entry points a plugin gets.
    -- So rather than scattering "Import", "Connection", "Re-import" through
    -- Plug-in Extras, a single "PicPeak" item opens a hub that dispatches to
    -- all of them — which also means one OS-level App Shortcut on this title
    -- reaches the entire plugin.
    --
    -- Two entries: the overview is the landing page, the importer is the
    -- shortcut past it for the repeat import — which is most of them.
    --
    -- Neither title equals LrPluginName. Lightroom draws the plugin name as a
    -- DISABLED section header above these items, so a matching title puts two
    -- identical rows in the submenu — and macOS App Shortcuts, which binds to
    -- the first title match, would attach to the header. That is moot in
    -- practice (no App Shortcut can reach these items at all: Lightroom builds
    -- them lazily when the menu opens, after key equivalents are applied at
    -- launch, verified against a real install) but a submenu that reads
    -- "PicPeak / PicPeak / PicPeak Importer" is worse for no gain.
    LrLibraryMenuItems = {
        {
            title = "PicPeak Overview",
            file = "PicPeakMenuItem.lua",
        },
        {
            title = "PicPeak Importer",
            file = "PicPeakImportMenuItem.lua",
        },
    },

    LrMetadataProvider = "MetadataProvider.lua",

    LrPluginInfoProvider = "PluginInfo.lua",

    LrPluginInfoURL = "https://github.com/bmachek/lrc-picpeak",

    VERSION = { major = 1, minor = 2, revision = 0, build = 0 },
}
