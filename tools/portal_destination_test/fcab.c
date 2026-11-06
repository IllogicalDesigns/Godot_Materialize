/* Portal FileChooser A/B test: the same client, the same Response
 * subscription, the plain file pick (no directory option). If the Response
 * arrives here and not with "directory", the backend's folder mode is the
 * broken half.
 */
#include <glib.h>
#include <gio/gio.h>

static GMainLoop *loop;

static void on_response(GDBusConnection *conn, const char *sender, const char *path,
                        const char *interface, const char *signal,
                        GVariant *params, gpointer data) {
    (void)conn; (void)sender; (void)interface; (void)signal; (void)data;
    g_print("[fctest] Response signal on %s\n", path);
    guint32 code = 0;
    GVariant *results = NULL;
    g_variant_get(params, "(u@a{sv})", &code, &results);
    g_print("[fctest] response code = %u\n", code);
    GVariant *uris = g_variant_lookup_value(results, "uris", G_VARIANT_TYPE("a@s"));
    if (uris) {
        GVariantIter iter;
        g_variant_iter_init(&iter, uris);
        g_print("[fctest] %u uris\n", (guint)g_variant_iter_n_children(&iter));
        GVariant *item = NULL;
        while (g_variant_iter_next(&iter, "s", &item)) {
            g_print("[fctest] uri = %s\n", g_variant_get_string(item, NULL));
            g_variant_unref(item);
        }
        g_variant_unref(uris);
    } else {
        g_print("[fctest] no uris key in the response\n");
    }
    g_variant_unref(results);
    g_main_loop_quit(loop);
}

static gboolean timeout_cb(gpointer data) {
    (void)data;
    g_print("[fctest] 60 seconds passed, no Response signal arrived\n");
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

int main(int argc, char *argv[]) {
    /* argv[1] = "dir" for the directory option, anything else for plain open */
    gboolean dir = argc > 1 && g_strcmp0(argv[1], "dir") == 0;
    GError *err = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!bus) {
        g_print("[fctest] no session bus: %s\n", err->message);
        return 1;
    }
    const char *unique = g_dbus_connection_get_unique_name(bus);
    g_print("[fctest] my unique name is %s, mode = %s\n", unique,
            dir ? "directory" : "file");

    guint sub = g_dbus_connection_signal_subscribe(bus,
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.portal.Request",
        "Response",
        NULL,
        unique,
        G_DBUS_SIGNAL_FLAGS_NONE,
        on_response,
        NULL,
        NULL);

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
        g_variant_new("(ssa{sv})", "", "Portal test", &opts),
        G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);
    if (!reply) {
        g_print("[fctest] request failed: %s\n", err->message);
        g_dbus_connection_signal_unsubscribe(bus, sub);
        return 1;
    }
    char *req_path = NULL;
    g_variant_get(reply, "(o)", &req_path);
    g_print("[fctest] request object path = %s\n", req_path);
    g_variant_unref(reply);

    loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add_seconds(60, timeout_cb, NULL);
    g_main_loop_run(loop);
    g_dbus_connection_signal_unsubscribe(bus, sub);
    g_free(req_path);
    return 0;
}
