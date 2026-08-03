using Toybox.Application as App;
using Toybox.Communications as Comm;
using Toybox.Lang;
using Toybox.PersistedContent;
using Toybox.System;
using Toybox.WatchUi as Ui;

// Talking to the logging server.
//
// Nothing here ever blocks the UI. A press is already durably queued by the time
// a sync starts, so a failure costs nothing but a retry.
(:background)
module Net {

    // Holds the job whose request is currently in flight.
    //
    // A view that starts a sync and then immediately pops itself would otherwise
    // let the job -- and the callback bound to it -- be collected before the
    // response arrives, so the ack would silently never be applied. A Method
    // keeps its receiver alive, so parking the job here retains the whole chain.
    //
    // One slot is enough: two presses in quick succession will drop the first
    // job, but every sync sends the entire queue, so the second request carries
    // both presses anyway. The cost of losing a job is a retry, never data.
    var inflight;

    function serverUrl() {
        var v = App.Properties.getValue("serverUrl");
        // Ternary rather than an early return: properties.xml declares a default,
        // so the type checker treats an explicit null-guard branch as dead code
        // and warns. The runtime check is still worth keeping.
        var s = (v == null) ? "" : v.toString();
        // A trailing slash would produce a double slash and a 404.
        if (s.length() > 0 && s.substring(s.length() - 1, s.length()).equals("/")) {
            s = s.substring(0, s.length() - 1);
        }
        return s;
    }

    function authToken() {
        var v = App.Properties.getValue("authToken");
        return (v == null) ? "" : v.toString();
    }

    function configured() {
        return serverUrl().length() > 0 && authToken().length() > 0;
    }

    function options(method) {
        return {
            :method => method,
            :headers => {
                "Content-Type"  => Comm.REQUEST_CONTENT_TYPE_JSON,
                // A header, not a query parameter, so the secret stays out of
                // any proxy access log on the way through.
                "Authorization" => "Bearer " + authToken()
            },
            :responseType => Comm.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
    }
}


// Pushes the queued presses. Used identically by the foreground app and the
// background service; only the completion callback differs.
(:background)
class SyncJob {

    hidden var _onDone;   // method(result as Boolean)
    hidden var _sent;     // ids in flight, for logging only

    function initialize(onDone) {
        _onDone = onDone;
    }

    function start() {
        if (!Net.configured()) {
            System.println("sync: server url / token not set");
            finish(false);
            return;
        }

        var q = Log.queue();
        if (q.size() == 0) {
            finish(true);
            return;
        }

        _sent = q.size();
        Comm.makeWebRequest(
            Net.serverUrl() + "/v1/events",
            { "presses" => q },
            Net.options(Comm.HTTP_REQUEST_METHOD_POST),
            method(:onResponse)
        );
    }

    // Signature must match what makeWebRequest declares, exactly -- the type
    // checker rejects a looser one.
    function onResponse(
        code as Lang.Number,
        data as Null or Lang.Dictionary or Lang.String or PersistedContent.Iterator
    ) as Void {
        if (code == 200 && data != null && data instanceof Lang.Dictionary) {
            Log.ack(data["acked"]);
            Log.reconcile(data["cur"]);
            System.println("sync: sent " + _sent + ", " + Log.pending() + " left");
            finish(true);
            return;
        }

        // -104 is BLE_CONNECTION_UNAVAILABLE: the phone is simply not there.
        // Expected and harmless -- the queue survives and the background service
        // will try again.
        System.println("sync: failed code=" + code);
        finish(false);
    }

    hidden function finish(ok) {
        if (_onDone != null) {
            _onDone.invoke(ok);
        }
    }
}


// Fetches the domain list so the names live only in the server's config.
class DomainsJob {

    hidden var _onDone;

    function initialize(onDone) {
        _onDone = onDone;
    }

    function start() {
        if (!Net.configured()) {
            finish(false);
            return;
        }
        Comm.makeWebRequest(
            Net.serverUrl() + "/v1/domains",
            null,
            Net.options(Comm.HTTP_REQUEST_METHOD_GET),
            method(:onResponse)
        );
    }

    function onResponse(
        code as Lang.Number,
        data as Null or Lang.Dictionary or Lang.String or PersistedContent.Iterator
    ) as Void {
        if (code != 200 || data == null || !(data instanceof Lang.Dictionary)) {
            finish(false);
            return;
        }
        var list = data["domains"];
        if (list == null || !(list instanceof Lang.Array)) {
            finish(false);
            return;
        }

        // Store only the short labels; the full names are what the server writes
        // into the calendar and the watch never needs them.
        var names = [];
        for (var i = 0; i < list.size(); i += 1) {
            var s = list[i]["s"];
            names.add((s == null) ? list[i]["n"] : s);
        }
        Log.setDomains(names);
        finish(true);
    }

    hidden function finish(ok) {
        if (_onDone != null) {
            _onDone.invoke(ok);
        }
    }
}
