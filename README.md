# standbycover.koplugin — book cover on the PocketBook standby screen

A [KOReader](https://koreader.rocks) plugin for PocketBook e-readers. It puts
the cover of the book you are reading on the **standby (lock) screen**, the one
shown after a double press of the power button, and optionally on the
**power-off screen**. It can also make the **boot screen** a capture of the
last page you read, so that a device that switched itself off after a long
standby seems to come back on that page at once.

Written for and tested on a PocketBook Era Lite (PB710), firmware 6.11,
KOReader 2026.07. Other PocketBooks with the Line theme should behave the
same, but have not been tried. On any other device the plugin does nothing.

## What you see

- **Standby:** the cover, fitted to the screen on a white page, instead of
  the firmware's sleeping-reader picture. Portrait and landscape.
- **Power-off:** the cover alone (optional, on by default), the same as the
  `pocketbookcover` plugin produced.
- A book without a cover gets its title and authors on the page instead.
- **Boot:** optionally, the page that was on the screen at the last standby
  (or at a power-off from KOReader's menu), exactly as it looked. With the
  PocketBook set to reopen the last book, KOReader then starts behind that
  page and the boot feels much shorter.

## Install

1. Download `standbycover.koplugin.zip` from the
   [latest release](https://github.com/glaucon1984/standbycover.koplugin/releases/latest)
   and unzip it into `applications/koreader/plugins/` on the device, so that
   `applications/koreader/plugins/standbycover.koplugin/main.lua` exists.
2. If you have `pocketbookcover.koplugin`, disable or remove it: it writes the
   same files. KOReader's built-in *Cover image* plugin can stay; it writes
   different files (the boot logo and `offlogo/cover.bmp`).
3. For the power-off image, set **Settings → Personalize → Logos → Power-off
   Logo** to the book cover in the PocketBook's own settings (that is also
   what `pocketbookcover` needed). For the boot screen, set **Boot Logo** to
   the book cover there too, and switch the plugin's boot-screen option on.
4. Restart KOReader and open a book. The standby screen shows the cover from
   the next double press on.

## Settings

In a book: **Menu → Screen → Standby cover**.

- **Show the book cover on the standby screen** (default on).
- **Also as the power-off image** (default on).
- **Boot screen: the last page read** (default off). At every standby and at
  a power-off from KOReader, a capture of the screen is stored as the boot
  screen. Nothing is written when the page has not changed since the last
  capture. KOReader's built-in *Cover image* plugin, if enabled, still
  stores the cover there when a book is opened; the next standby replaces
  it with the page.
- **Refresh the firmware's copy after each write** (default on), see below.
- **Update now** rewrites everything for the open book.
- **Restore the firmware's standby image** removes the plugin's files (or
  puts back the ones that were there before) and refreshes the firmware.

## How it works

The firmware's Line theme draws the lock screen from
`system/resources/Line/taskmgr_lock_background.bmp` (and
`taskmgr_lock_background_landscape.bmp`) whenever those files exist; the
plugin writes them as greyscale BMPs at panel size when a book is opened.
The power-off screen comes from `system/logo/bookcover`.

The firmware's task manager keeps a copy of the lock image, loaded when
KOReader starts, so merely rewriting the file changes nothing until the next
restart. After each write the plugin therefore asks it to reload the file, by
sending it a *settings changed* event through `iv2sh`, a method found by the
author of
[coverprogresspocketbook.koplugin](https://github.com/apastuszak/coverprogresspocketbook.koplugin).
That request is only ever sent while the device is awake. Sent as the device
goes to standby, it leaves the Era Lite half asleep: LED on, no wake-up from
the first press, front light off afterwards.

Measured on the Era Lite: writing both lock images takes about 0.4 s, the
reload request about 0.3 s.

The boot screen is a flash partition that only the firmware's own tool
writes, `iv2sh WriteStartupLogo <bmp>`, which is what KOReader's *Cover
image* plugin runs when a book is opened. The plugin captures the panel as
shown (rotation and night mode included), writes it to a BMP in RAM and runs
the tool in the foreground, keeping the device awake meanwhile: the firmware
suspends the CPU a few seconds after the last input whatever is running, and
a write to that partition must not be cut short. The tool takes a few
seconds; the `StandbyCover:` log lines show how long.

### Why there is no "progress pushed" note on it

The double-press lock draws the lock screen from the firmware's copy the
moment the button is pressed, before KOReader hears of it, and the firmware
discards panel refreshes from a task it has hidden. So nothing that happens
during that standby, such as a progress push by kosyncwifi, can be shown on
its screen. A note could only ever describe the previous standby, or require
locking from a KOReader action instead of the button. Neither is worth it.

### Orientation

The firmware turns the lock image to the device's orientation by itself, so
the standby cover is upright however you hold the device. The power-off image
it draws in the panel's own orientation, so the plugin turns that one by 180°
when the screen is upside down (or in clockwise landscape), as KOReader's
Cover image plugin does, and rewrites it when you rotate the screen while
reading. The boot screen is a capture of the panel, so it comes back exactly
as it was.

## Troubleshooting

Lines starting with `StandbyCover:` in `koreader/crash.log` show every write
and reload request with its trigger and timing.

- The standby screen still shows the firmware's picture: open a book once
  (the files are written when a book is opened), then double-press again.
- The cover changed but the standby screen did not: *Refresh the firmware's
  copy* may be off, or `iv2sh` could not find the task manager; restarting
  KOReader reloads the image too.

## Uninstall

Use **Restore the firmware's standby image** first, then delete the plugin
folder or disable it in Plugin management.

## License

AGPL-3.0-or-later, like KOReader.
