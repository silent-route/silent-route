# dmgbuild settings for the release disk image: the app on the left,
# Applications on the right, an arrow between them, in a window just big
# enough for them, also with Finder's tab bar and path bar shown.
#
# Used by scripts/package-release.sh:
#   dmgbuild -s scripts/dmg-settings.py -D app=... -D icon=... -D background=... "<volume name>" out.dmg
#
# Positions match scripts/make-dmg-background.swift.

import os.path

app = defines["app"]  # noqa: F821 (given by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
# No hide_extensions: it marks the app with Finder information, which
# breaks the signature check (codesign --verify --strict) the updater runs.
icon = defines["icon"]  # noqa: F821

background = defines["background"]  # noqa: F821
# The title bar included.
window_rect = ((200, 200), (540, 340))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (145, 132),
    "Applications": (395, 132),
}
