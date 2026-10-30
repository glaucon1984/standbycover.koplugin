--[[--
Standby cover for PocketBook.

Puts the cover of the book being read on the PocketBook's standby (lock)
screen and, optionally, on its power-off screen, and can make the boot
screen a capture of the last page read, so that a device that switched
itself off after a long standby seems to come back on the page at once.

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
- The boot screen is a flash partition that only `iv2sh WriteStartupLogo`
  writes (what KOReader's Cover image plugin runs at book open), shown when
  "Boot logo" is set to the book cover. The plugin can write a capture of
  the panel there at every standby and at a power-off from KOReader. The
  tool takes seconds and the firmware suspends the CPU a few seconds after
  the last input whatever is running, so the device is kept awake
  (iv_sleepmode(0)) while it runs, and it runs in the foreground.

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
local ffi = require("ffi")
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
local SETTING_BOOTLOGO = "standbycover_bootlogo"

-- The capture is written here (RAM) and handed to the firmware's tool, which
-- copies it into the boot logo partition.
local BOOT_IMAGE = "/tmp/standbycover_boot.bmp"
local BOOT_TOOL = "/ebrmain/bin/iv2sh"

-- Shared between the reader's and the file manager's plugin instances (the
-- process keeps this module).
local State = {
    cover = nil,   -- BlitBuffer of the current book's cover, or nil
    title = nil,
    authors = nil,
    pending_reload = false,
    boot_hash = nil, -- of the panel last written as the boot screen
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
local function bootLogoEnabled() return G_reader_settings:isTrue(SETTING_BOOTLOGO) end

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

-- The firmware turns the lock image to match the device's orientation by
-- itself, but draws the power-off image in the panel's own orientation, so
-- a device switched off while held upside down showed it upside down. The
-- power-off image is turned by 180° for the rotation modes KOReader's Cover
-- image plugin turns it for (upside down, and clockwise landscape).
local function orientForPanel(bb)
    local Screen = Device.screen
    local mode = Screen:getRotationMode()
    if mode == Screen.DEVICE_ROTATED_UPSIDE_DOWN or mode == Screen.DEVICE_ROTATED_CLOCKWISE then
        local turned = bb:rotatedCopy(180)
        bb:free()
        return turned
    end
    return bb
end

local function writeImage(bb, path, orient)
    if orient then
        bb = orientForPanel(bb)
    end
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
    local ok = writeImage(compose(w, h), POWEROFF_COVER, true)
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
-- Boot screen: a capture of the panel
-------------------------------------------------------------------------------

-- A copy of the framebuffer as the panel shows it: in the panel's own
-- orientation (rotation cleared) and with the stored bytes as they are
-- (inverse cleared), so night mode and a turned screen come out as seen.
local function capturePanel()
    local fb = Device.screen.bb
    local rotation, inverse = fb:getRotation(), fb:getInverse()
    fb:setRotation(0)
    fb:setInverse(0) -- a number in the blitbuffer, not a boolean
    local w, h = fb:getWidth(), fb:getHeight()
    local dump = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    dump:blitFrom(fb, 0, 0, 0, 0, w, h)
    fb:setRotation(rotation)
    fb:setInverse(inverse)
    return dump
end

-- Cheap fingerprint of a BB8: every 61st byte of every 7th row. Enough to
-- tell a page from the next and to skip rewriting the flash for the same
-- page (a menu open over it counts as a change, which is fine).
local function quickHash(bb)
    local data = ffi.cast("uint8_t*", bb.data)
    local w, h, stride = bb:getWidth(), bb:getHeight(), tonumber(bb.stride)
    local a, b = 1, 0
    for y = 0, h - 1, 7 do
        local row = data + y * stride
        for x = 0, w - 1, 61 do
            a = (a + row[x]) % 65521
            b = (b + a) % 65521
        end
    end
    return b * 65536 + a
end

-- Captures the panel and makes it the boot screen, in the foreground, with
-- the device kept awake meanwhile. Skipped when the panel has not changed
-- since the last write.
function StandbyCover:writeBootImage(reason)
    if not bootLogoEnabled() then return end
    local t0 = time.now()
    local ok, err = pcall(function()
        local dump = capturePanel()
        local hash = quickHash(dump)
        if hash == State.boot_hash then
            dump:free()
            logger.info("StandbyCover: boot screen unchanged, not written (" .. tostring(reason) .. ")")
            return
        end
        local written = dump:writeToFile(BOOT_IMAGE, "bmp", 100, true)
        dump:free()
        if not written then
            logger.warn("StandbyCover: could not write", BOOT_IMAGE)
            return
        end
        pcall(Device.setAutoStandby, Device, false)
        local rc = os.execute("sync; " .. BOOT_TOOL .. " WriteStartupLogo " .. util.shell_escape({ BOOT_IMAGE }))
        pcall(Device.setAutoStandby, Device, true)
        os.remove(BOOT_IMAGE)
        if rc == 0 then
            State.boot_hash = hash
        end
        logger.info("StandbyCover: boot screen written (" .. tostring(reason) .. "), rc", rc,
            "in", time.to_s(time.since(t0)), "s")
    end)
    if not ok then
        pcall(Device.setAutoStandby, Device, true)
        logger.warn("StandbyCover: boot screen failed:", err)
    end
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

-- The screen was turned: the power-off image follows it (the lock image
-- needs nothing, the firmware turns it).
function StandbyCover:onSetRotationMode()
    if not Device:isPocketBook() or not isEnabled() or not powerOffEnabled() or not self:inReader() then return end
    UIManager:scheduleIn(0.5, function()
        if self.ui and self.ui.document then
            self:writePowerOffCover("rotation")
        end
    end)
end

-- Standby: the page is still on the panel (KOReader draws no sleep screen
-- on PocketBook), so this is the capture for the boot screen. Also sent
-- when the firmware's menu or a USB prompt takes the foreground; the hash
-- keeps those from rewriting the flash for nothing.
function StandbyCover:onSuspend()
    if not Device:isPocketBook() or not self:inReader() then return end
    self:writeBootImage("suspend")
end

-- Power off from KOReader's own menu: the firmware powers down right after.
function StandbyCover:onPowerOff()
    if not Device:isPocketBook() or not self:inReader() then return end
    self:writeBootImage("power off")
end
StandbyCover.onReboot = StandbyCover.onPowerOff

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
                text = _("Boot screen: the last page read"),
                help_text = _([[At every standby, and at a power-off from KOReader, a capture of the page on the screen is stored as the device's boot screen, provided "Boot logo" is set to the book cover in the PocketBook settings (Settings → Personalize → Logos). When the device switches itself off after a long standby and boots again, the page is on the screen while KOReader starts.

The firmware's tool that stores it takes a few seconds, during which the device is kept awake. Nothing is written when the page has not changed.]]),
                checked_func = bootLogoEnabled,
                callback = function()
                    G_reader_settings:saveSetting(SETTING_BOOTLOGO, not bootLogoEnabled())
                    State.boot_hash = nil
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
