/* The emitter half of the directed-delivery control: send a Response-shaped
 * signal to the listener's unique name, the way the portal emits the
 * FileChooser response. argv[1] is the listener's unique name.
 */
#include <glib.h>
#include <gio/gio.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        g_print("[fcsend] usage: fcsend <unique name>\n");
        return 1;
    }
    GError *err = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!bus) {
        g_print("[fcsend] no session bus: %s\n", err->message);
        return 1;
    }
    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&opts, "{sv}", "marker", g_variant_new_string("control"));
    /* "@a{sv}" takes a GVariant, so end the builder and pass the dict. */
    GVariant *params = g_variant_new("(u@a{sv})", (guint32)99,
                                     g_variant_builder_end(&opts));

    if (!g_dbus_connection_emit_signal(bus, argv[1],
            "/org/freedesktop/portal/desktop/request/1_999/t",
            "org.freedesktop.portal.Request", "Response", params, &err)) {
        g_print("[fcsend] emit failed: %s\n", err ? err->message : "unknown");
        return 1;
    }
    g_print("[fcsend] directed signal sent to %s\n", argv[1]);
    return 0;
}
