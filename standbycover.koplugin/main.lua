--[[--
Standby cover for PocketBook.

Puts the cover of the book being read on the PocketBook's standby (lock)
screen and, optionally, on its power-off screen.

How it works (PocketBook Era Lite, firmware 6.11, KOReader 2026.07):

- The firmware's Line theme draws the double-press lock screen from
  /mnt/ext1/system/resources/Line/taskmgr_lock_background.bmp, plus a
  _landscape twin, whenever those files exist. An opaque greyscale BMP at
  panel size replaces the frosted page and the stock picture entirely.
- The firmware's task manager keeps a copy of that image, loaded when
  KOReader is launched, so after each write the plugin asks it to reload by
  sending it EVT_CONFIGCHANGED (154) through iv2sh (a method found by the
  author of coverprogresspocketbook.koplugin). Never while the device is
  going to sleep: on the Era Lite that leaves the device half asleep (LED
  on, no wake-up from the first press, front light off afterwards).
- The power-off screen comes from /mnt/ext1/system/logo/bookcover when
  "Power-off logo" is set to the book cover in the PocketBook settings.

@module koplugin.StandbyCover
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local _ = require("gettext")

local LINE_DIR = "/mnt/ext1/system/resources/Line"
local LOCK_PORTRAIT = LINE_DIR .. "/taskmgr_lock_background.bmp"
local LOCK_LANDSCAPE = LINE_DIR .. "/taskmgr_lock_background_landscape.bmp"
local POWEROFF_COVER = "/mnt/ext1/system/logo/bookcover"
local BACKUP_SUFFIX = ".orig"

-- Asks the firmware's task manager to reload the lock image. Fixed text, run
-- in the background so a slow or missing iv2sh can never stall the reader.
local RELOAD_CMD =
    [[(sync; p=$(ps | grep '[t]askmgr\.app' | grep -v visualizer | awk '{print $1}' | head -n 1); ]] ..
    [[[ -n "$p" ] && /ebrmain/bin/iv2sh SendEventTo "$p" 154 0) >/dev/null 2>&1 &]]

local SETTING_ENABLED = "standbycover_enabled"
local SETTING_POWEROFF = "standbycover_poweroff"
local SETTING_RELOAD = "standbycover_reload"

-- Shared between the reader's and the file manager's plugin instances (the
-- process keeps this module).
local State = {
    cover = nil,   -- BlitBuffer of the current book's cover, or nil
    title = nil,
    authors = nil,
    pending_reload = false,
}

local StandbyCover = WidgetContainer:extend{
    name = "standbycover",
    is_doc_only = false,
}

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

local function isEnabled() return G_reader_settings:nilOrTrue(SETTING_ENABLED) end
local function powerOffEnabled() return G_reader_settings:nilOrTrue(SETTING_POWEROFF) end
local function reloadEnabled() return G_reader_settings:nilOrTrue(SETTING_RELOAD) end

-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------

-- Scaled copy of `img` that fits in w x h, keeping its aspect ratio, and the
-- size it got. The copy may be `img` itself when nothing had to change.
local function fitInto(img, w, h)
    local iw, ih = img:getWidth(), img:getHeight()
    local scale = math.min(w / iw, h / ih)
    local sw = math.max(1, math.floor(iw * scale + 0.5))
    local sh = math.max(1, math.floor(ih * scale + 0.5))
    -- `false`: keep `img`; scaleBlitBuffer frees its input by default.
    return RenderImage:scaleBlitBuffer(img, sw, sh, false), sw, sh
end

-- A book without a cover gets its title (and authors) centred on the page.
local function paintTitle(bb, w, h, title, authors)
    local width = math.floor(w * 0.8)
    local y = math.floor(h * 0.35)
    for i, line in ipairs({ { title or _("Untitled"), 32 }, { authors, 22 } }) do
        local text, size = line[1], line[2]
        if text and text ~= "" then
            local box = TextBoxWidget:new{
                text = text,
                face = Font:getFace("NotoSerif-Regular.ttf", size) or Font:getFace("tfont", size),
                width = width,
                alignment = "center",
            }
            local bh = box:getSize().h
            box:paintTo(bb, math.floor((w - width) / 2), y)
            box:free()
            y = y + bh + (i == 1 and Device.screen:scaleBySize(24) or 0)
        end
    end
end

-- Full image for a w x h panel: white page with the cover fitted and
-- centred, or the title.
local function compose(w, h)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    if State.cover then
        local scaled, sw, sh = fitInto(State.cover, w, h)
        bb:blitFrom(scaled, math.floor((w - sw) / 2), math.floor((h - sh) / 2), 0, 0, sw, sh)
        if scaled ~= State.cover then scaled:free() end
    else
        paintTitle(bb, w, h, State.title, State.authors)
    end
    return bb
end

local function writeImage(bb, path)
    local ok = bb:writeToFile(path, "bmp", 100, true)
    bb:free()
    return ok and true or false
end

-- Keeps the firmware's (or the user's) own file once, next to it.
local function backupOnce(path)
    if lfs.attributes(path, "mode") ~= "file" then return end
    if lfs.attributes(path .. BACKUP_SUFFIX, "mode") == "file" then return end
    if not ffiutil.copyFile(path, path .. BACKUP_SUFFIX) then
        logger.info("StandbyCover: kept a copy of", path)
    end
end

-- Puts back the backup, or removes our file when there was none.
local function restoreFile(path)
    if lfs.attributes(path .. BACKUP_SUFFIX, "mode") == "file" then
        ffiutil.copyFile(path .. BACKUP_SUFFIX, path)
        os.remove(path .. BACKUP_SUFFIX)
    else
        os.remove(path)
    end
end

-------------------------------------------------------------------------------
-- Writing and the firmware reload
-------------------------------------------------------------------------------

-- Panel size in portrait, whatever the current rotation.
local function panelSize()
    local Screen = Device.screen
    local w, h = Screen:getScreenWidth(), Screen:getScreenHeight()
    if w > h then w, h = h, w end
    return w, h
end

-- Sends the reload now, or marks it for the next wake-up when the device is
-- going to sleep.
function StandbyCover:requestReload(reason)
    if not reloadEnabled() then return end
    if reason == "suspend" then
        State.pending_reload = true
        logger.info("StandbyCover: lock image reload deferred to wake-up")
        return
    end
    State.pending_reload = false
    os.execute(RELOAD_CMD)
    logger.info("StandbyCover: asked taskmgr.app to reload the lock image (" .. tostring(reason) .. ")")
end

-- Writes the two lock-screen images and asks for the reload.
function StandbyCover:writeLockImages(reason)
    local w, h = panelSize()
    local t0 = time.now()
    util.makePath(LINE_DIR)
    backupOnce(LOCK_PORTRAIT)
    backupOnce(LOCK_LANDSCAPE)
    local ok1 = writeImage(compose(w, h), LOCK_PORTRAIT)
    local ok2 = writeImage(compose(h, w), LOCK_LANDSCAPE)
    logger.info("StandbyCover: lock images written (" .. tostring(reason) .. ")",
        ok1 and ok2 and "ok" or "FAILED", "in", time.to_s(time.since(t0)), "s")
    if ok1 and ok2 then
        self:requestReload(reason)
    end
    return ok1 and ok2
end

-- The power-off screen: the cover alone.
function StandbyCover:writePowerOffCover(reason)
    local w, h = panelSize()
    local t0 = time.now()
    local ok = writeImage(compose(w, h), POWEROFF_COVER)
    logger.info("StandbyCover: power-off cover written (" .. tostring(reason) .. ")",
        ok and "ok" or "FAILED", "in", time.to_s(time.since(t0)), "s")
    return ok
end

function StandbyCover:writeAll(reason)
    local ok = self:writeLockImages(reason)
    if powerOffEnabled() then
        ok = self:writePowerOffCover(reason) and ok
    end
    return ok
end

-------------------------------------------------------------------------------
-- The current book
-------------------------------------------------------------------------------

local function freeCover()
    if State.cover then
        State.cover:free()
        State.cover = nil
    end
end

function StandbyCover:loadBook()
    freeCover()
    local document = self.ui.document
    local file = document and document.file
    local props = self.ui.doc_props or {}
    State.title = props.display_title or (file and file:match("([^/]+)$")) or nil
    State.authors = props.authors
    local cover = FileManagerBookInfo:getCoverImage(document)
    State.cover = cover or nil
    logger.info("StandbyCover: book loaded:", State.title, cover and "with cover" or "without cover")
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

function StandbyCover:init()
    if not Device:isPocketBook() then return end
    self.ui.menu:registerToMainMenu(self)
end

function StandbyCover:onReaderReady()
    if not Device:isPocketBook() or not isEnabled() then return end
    self:loadBook()
    self:writeAll("open")
end

function StandbyCover:onResume()
    if State.pending_reload then
        self:requestReload("resume")
    end
end

-------------------------------------------------------------------------------
-- Menu
-------------------------------------------------------------------------------

function StandbyCover:inReader()
    return self.ui and self.ui.document ~= nil
end

function StandbyCover:updateNow()
    if not self:inReader() then return end
    self:loadBook()
    local ok = self:writeAll("manual")
    UIManager:show(InfoMessage:new{
        text = ok and _("Standby cover updated.") or _("Could not write the standby cover; see crash.log."),
        timeout = 3,
    })
end

function StandbyCover:restoreFirmwareImage()
    restoreFile(LOCK_PORTRAIT)
    restoreFile(LOCK_LANDSCAPE)
    self:requestReload("restore")
    UIManager:show(InfoMessage:new{
        text = _("The firmware's own standby image is back."),
        timeout = 3,
    })
end

function StandbyCover:addToMainMenu(menu_items)
    menu_items.standbycover = {
        text = _("Standby cover"),
        sorting_hint = "screen",
        sub_item_table = {
            {
                text = _("Show the book cover on the standby screen"),
                help_text = _([[Writes the cover of the open book as the PocketBook's lock-screen image (system/resources/Line/taskmgr_lock_background.bmp), so the standby screen shows it instead of the firmware's picture.]]),
                checked_func = isEnabled,
                callback = function()
                    G_reader_settings:flipNilOrTrue(SETTING_ENABLED)
                    if isEnabled() and self:inReader() then
                        self:loadBook()
                        self:writeAll("enable")
                    end
                end,
            },
            {
                text = _("Also as the power-off image"),
                help_text = _([[Writes the cover to system/logo/bookcover as well, which the firmware shows when the device is switched off, provided "Power-off logo" is set to the book cover in the PocketBook settings (Settings → Personalize → Logos). Replaces the pocketbookcover plugin.]]),
                checked_func = powerOffEnabled,
                callback = function()
                    G_reader_settings:flipNilOrTrue(SETTING_POWEROFF)
                    if powerOffEnabled() and isEnabled() and self:inReader() then
                        self:writePowerOffCover("setting")
                    end
                end,
            },
            {
                text = _("Refresh the firmware's copy after each write"),
                help_text = _([[The firmware keeps a copy of the standby image, loaded when KOReader starts. After each write the plugin asks it to reload the file (by sending its task manager a "settings changed" event). Without this, a new cover shows only after KOReader is restarted.]]),
                checked_func = reloadEnabled,
                callback = function()
                    G_reader_settings:flipNilOrTrue(SETTING_RELOAD)
                end,
                separator = true,
            },
            {
                text = _("Update now"),
                enabled_func = function() return self:inReader() end,
                callback = function() self:updateNow() end,
                keep_menu_open = true,
            },
            {
                text = _("Restore the firmware's standby image"),
                help_text = _([[Removes the plugin's lock-screen images (or puts back the ones that were there before) and refreshes the firmware's copy.]]),
                callback = function() self:restoreFirmwareImage() end,
                keep_menu_open = true,
            },
        },
    }
end

return StandbyCover
