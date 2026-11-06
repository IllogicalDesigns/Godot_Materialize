/* Directed-delivery control, two-process: this listener subscribes for a
 * Response-shaped signal addressed to its own unique name, and the emitter
 * program (fcsend) sends exactly that signal to it from a separate client.
 * If the listener prints, directed delivery works and a missing portal
 * Response is a portal-side emission problem.
 */
#include <glib.h>
#include <gio/gio.h>

static void on_response(GDBusConnection *conn, const char *sender, const char *path,
                        const char *interface, const char *signal,
                        GVariant *params, gpointer data) {
    (void)conn; (void)path; (void)interface; (void)signal; (void)data;
    g_print("[fclisten] directed signal received from %s\n", sender);
    guint32 code = 0;
    GVariant *results = NULL;
    g_variant_get(params, "(u@a{sv})", &code, &results);
    g_print("[fclisten] code = %u\n", code);
    if (results) g_variant_unref(results);
}

static gboolean quit_cb(gpointer data) {
    (void)data;
    g_print("[fclisten] done\n");
    g_main_loop_quit((GMainLoop *)data);
    return G_SOURCE_REMOVE;
}

int main(void) {
    GError *err = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!bus) {
        g_print("[fclisten] no session bus: %s\n", err->message);
        return 1;
    }
    g_print("[fclisten] my unique name is %s\n",
            g_dbus_connection_get_unique_name(bus));

    g_dbus_connection_signal_subscribe(bus,
        NULL, "org.freedesktop.portal.Request", "Response", NULL,
        NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_response, NULL, NULL);

    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add_seconds(30, quit_cb, loop);
    g_main_loop_run(loop);
    return 0;
}
