/* Request object lifetime probe: subscribe for the Response signal, send
 * OpenFile, then poll the request object path every second. While the dialog
 * is open the object exists; the portal unexports it when the response is
 * emitted. The log's timeline says which side is stuck: object never vanishes
 * = the GTK dialog never answered; object vanishes with no signal = the
 * portal emitted the response and our directed subscription missed it.
 */
#include <glib.h>
#include <gio/gio.h>

static GMainLoop *loop;
static GDBusConnection *bus;
static char *req_path;

static void on_response(GDBusConnection *conn, const char *sender, const char *path,
                        const char *interface, const char *signal,
                        GVariant *params, gpointer data) {
    (void)conn; (void)sender; (void)interface; (void)signal; (void)data;
    g_print("[fcpoll] RESPONSE SIGNAL on %s\n", path);
    guint32 code = 0;
    GVariant *results = NULL;
    g_variant_get(params, "(u@a{sv})", &code, &results);
    g_print("[fcpoll] response code = %u\n", code);
    GVariant *uris = g_variant_lookup_value(results, "uris", G_VARIANT_TYPE("a@s"));
    if (uris) {
        g_print("[fcpoll] %u uris\n", (guint)g_variant_n_children(uris));
        GVariant *item = NULL;
        gsize i;
        for (i = 0; i < g_variant_n_children(uris); i++) {
            item = g_variant_get_child_value(uris, i);
            g_print("[fcpoll] uri = %s\n", g_variant_get_string(item, NULL));
            g_variant_unref(item);
        }
        g_variant_unref(uris);
    }
    if (results) g_variant_unref(results);
    g_main_loop_quit(loop);
}

static gboolean poll_cb(gpointer data) {
    (void)data;
    GError *err = NULL;
    GVariant *reply = g_dbus_connection_call_sync(bus,
        "org.freedesktop.portal.Desktop", req_path,
        "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", "org.freedesktop.portal.Request", "Response"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 2000, NULL, &err);
    if (reply) {
        g_print("[fcpoll] object exists, Response property readable\n");
        g_variant_unref(reply);
    } else {
        g_print("[fcpoll] object gone: %s\n", err ? err->message : "no reply");
        g_clear_error(&err);
    }
    return G_SOURCE_CONTINUE;
}

static gboolean quit_cb(gpointer data) {
    (void)data;
    g_print("[fcpoll] 60 seconds, giving up\n");
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

int main(int argc, char *argv[]) {
    gboolean dir = argc > 1 && g_strcmp0(argv[1], "dir") == 0;
    GError *err = NULL;
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!bus) {
        g_print("[fcpoll] no session bus: %s\n", err->message);
        return 1;
    }
    const char *unique = g_dbus_connection_get_unique_name(bus);
    g_print("[fcpoll] my unique name is %s, mode = %s\n", unique,
            dir ? "directory" : "file");

    guint sub = g_dbus_connection_signal_subscribe(bus,
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.portal.Request",
        "Response",
        NULL, unique, G_DBUS_SIGNAL_FLAGS_NONE, on_response, NULL, NULL);

    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
    if (dir) {
        g_variant_builder_add(&opts, "{sv}", "directory", g_variant_new_boolean(TRUE));
    }

    GVariant *reply = g_dbus_connection_call_sync(bus,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.FileChooser",
        "OpenFile",
        g_variant_new("(ssa{sv})", "", "Portal lifetime test", &opts),
        G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);
    if (!reply) {
        g_print("[fcpoll] request failed: %s\n", err->message);
        return 1;
    }
    g_variant_get(reply, "(o)", &req_path);
    g_print("[fcpoll] request object path = %s\n", req_path);
    g_variant_unref(reply);

    loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add_seconds(1, poll_cb, NULL);
    g_timeout_add_seconds(60, quit_cb, NULL);
    g_main_loop_run(loop);
    g_dbus_connection_signal_unsubscribe(bus, sub);
    return 0;
}
