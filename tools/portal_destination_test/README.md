# Portal destination-header test

The evidence behind `tests/save_dialog_probe.gd`'s "native is dead here"
note: Godot's X11 display server asks the xdg-desktop-portal for native file
dialogs, and its match rule for the portal's response carries a
`destination=` attribute (`platform/linuxbsd/freedesktop_portal_desktop.cpp`
line 638 in Godot's source):

```
type='signal',sender='org.freedesktop.portal.Desktop',path='<request object>',
interface='org.freedesktop.portal.Request',member='Response',destination='<our unique bus name>'
```

The D-Bus daemon forwards a directed signal **with the destination header
stripped**, so a client-side rule that tests `destination=` never matches. Godot
therefore never sees the portal's Response, `dir_selected` / `file_selected`
never fire, and nothing is saved. These four programs show it, and show the
portal side is fine.

Build (needs glib/gio dev headers):

```
gcc -O0 -g -o fcab fcab.c $(pkg-config --cflags --libs glib-2.0 gio-2.0)
gcc -O0 -g -o fclisten fclisten.c $(pkg-config --cflags --libs glib-2.0 gio-2.0)
gcc -O0 -g -o fcsend fcsend.c $(pkg-config --cflags --libs glib-2.0 gio-2.0)
gcc -O0 -g -o fcpoll fcpoll.c $(pkg-config --cflags --libs glib-2.0 gio-2.0)
```

- `fcab [dir|file]` — the portal client: OpenFile with (or without) the
  `directory` option, subscribed for the Response with a destination filter.
  Both modes get no response, folder and file picks alike.
- `fcpoll dir` — the same request plus a 1 s poll of the request object. The
  object exists for ~40 s, then vanishes the moment the user presses Open: the
  portal **does** answer, and unexports the request object; only the signal
  delivery is lost.
- `fclisten` + `fcsend <unique name>` — the two-process control. `fclisten`
  subscribes with a `destination=` filter, `fcsend` emits a Response-shaped
  signal addressed to it: the signal is **not** received. With the destination
  filter removed, the identical directed signal **is** received. That is the
  mechanism Godot loses the pick by.

Run the control:

```
./fclisten &            # prints its unique name :1.NNN
./fcsend ":1.NNN"       # directed signal, addressed at the listener
```

Expected log: with the filter, nothing; after removing the
`destination=` term from the subscription, `directed signal received`.

The fix for Godot itself is to drop `destination=` from the response match
rule (upstream issue territory). Until then the port uses Godot's own
FileDialogs with `ACCESS_FILESYSTEM` (`access = 2`, `use_native_dialog` off in
`scenes/main.tscn`), which browse and write the real filesystem, and
`tests/save_dialog_probe.tscn` drives the real Choose button press end to end.
