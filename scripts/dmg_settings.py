# dmgbuild settings for the DNS Pulse installer window: the app on the left, an arrow, and Applications on the
# right, over the background from scripts/render_dmg_background.swift. Used by scripts/make_dmg.sh, which passes
# the paths with -D app=… -D background=… -D icon=….
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "ULFO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]

background = defines["background"]
# The background's size plus the title bar.
window_rect = ((200, 140), (640, 408))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 128
text_size = 13
icon_locations = {
    app_name: (160, 185),
    "Applications": (480, 185),
}
