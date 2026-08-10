using Toybox.Application as App;
using Toybox.Time;
using Toybox.Lang;

// Local state and the durable press queue.
//
// Every button press is appended here FIRST and only then sent. That ordering is
// the whole point: a press made with the phone out of range must still be
// recorded, and must still be correct once it eventually syncs.
//
// Storage is shared between the foreground app and the background service, so
// both read and write this same queue.
// (:background) keeps this in the background process's image. That process gets
// only 32KB on the fenix 6 Pro versus 1.25MB for the app, so anything not
// annotated -- all the UI, Graphics, Menu2, Timer -- is left out of it.
(:background)
module Log {

    const KEY_QUEUE   = "q";      // Array of press dictionaries awaiting ack
    const KEY_QCOUNT  = "qn";     // Size of that array, stored separately
    const KEY_NEXTID  = "nid";    // Monotonic press id counter
    const KEY_CUR     = "cur";    // Domain index currently running, or null
    const KEY_SINCE   = "since";  // Epoch seconds the current domain started
    const KEY_DOMAINS = "doms";   // Cached short names from the server

    // The watch can hold roughly a month of heavy use offline. Beyond this the
    // oldest presses are dropped rather than growing storage without bound.
    const MAX_QUEUE = 200;

    // Names used until the server's list arrives. Order must match config.yaml.
    const DEFAULT_DOMAINS = [
        "Compounding",
        "Enriching",
        "Essential",
        "Prof: Other",
        "Prof: Self",
        "Unfocused",
        "Waste"
    ];

    function now() {
        // Moment.value() is seconds since the UNIX epoch. If this ever returns a
        // Garmin-epoch value instead, the server's plausibility guard rejects the
        // press and logs it loudly rather than writing events into 1989.
        return Time.now().value();
    }

    // -- press ids -------------------------------------------------------

    // Seeded from the clock rather than from zero: reinstalling the app wipes
    // storage, and restarting at 1 would collide with ids the server has already
    // applied, which it would then skip as duplicates.
    function nextId() {
        var id = App.Storage.getValue(KEY_NEXTID);
        if (id == null || !(id instanceof Lang.Number)) {
            id = now();
        }
        App.Storage.setValue(KEY_NEXTID, id + 1);
        return id;
    }

    // -- queue -----------------------------------------------------------

    function queue() {
        var q = App.Storage.getValue(KEY_QUEUE);
        if (q == null || !(q instanceof Lang.Array)) {
            return [];
        }
        return q;
    }

    // Reads the stored count rather than the queue itself. The status line asks
    // for this on every redraw, and queue() would rebuild up to MAX_QUEUE
    // dictionaries out of storage just to have its size taken and be discarded.
    function pending() {
        var n = App.Storage.getValue(KEY_QCOUNT);
        if (n == null || !(n instanceof Lang.Number)) {
            // Absent on an install that predates the counter, so derive it once
            // from the queue and seed it.
            n = queue().size();
            App.Storage.setValue(KEY_QCOUNT, n);
        }
        return n;
    }

    // The only writer of KEY_QUEUE, which is what keeps the count honest.
    function saveQueue(q) {
        if (q.size() > MAX_QUEUE) {
            q = q.slice(q.size() - MAX_QUEUE, null);
        }
        App.Storage.setValue(KEY_QUEUE, q);
        App.Storage.setValue(KEY_QCOUNT, q.size());
    }

    // Record a press. domainIdx is null for a stop.
    function push(action, domainIdx) {
        var entry = {
            "id" => nextId(),
            "a"  => action,
            "t"  => now()
        };
        if (domainIdx != null) {
            entry["d"] = domainIdx;
        }

        var q = queue();
        q.add(entry);
        saveQueue(q);
        return entry;
    }

    // Drop everything the server confirmed it applied.
    function ack(ackedIds) {
        if (ackedIds == null || !(ackedIds instanceof Lang.Array)) {
            return;
        }
        var q = queue();
        var kept = [];
        for (var i = 0; i < q.size(); i += 1) {
            var id = q[i]["id"];
            var found = false;
            for (var j = 0; j < ackedIds.size(); j += 1) {
                if (ackedIds[j] == id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                kept.add(q[i]);
            }
        }
        saveQueue(kept);
    }

    // -- current domain --------------------------------------------------

    function current() {
        return App.Storage.getValue(KEY_CUR);
    }

    function since() {
        var s = App.Storage.getValue(KEY_SINCE);
        return (s == null) ? 0 : s;
    }

    function setCurrent(domainIdx, startTs) {
        App.Storage.setValue(KEY_CUR, domainIdx);
        App.Storage.setValue(KEY_SINCE, startTs);
    }

    function clearCurrent() {
        App.Storage.setValue(KEY_CUR, null);
        App.Storage.setValue(KEY_SINCE, 0);
    }

    // The server owns the truth about what is open. When it reports back,
    // believe it over local state -- that repairs the watch after a reinstall or
    // an edit made directly in Google Calendar.
    function reconcile(cur) {
        if (pending() > 0) {
            // Local state is ahead of the server; leave it alone until it drains.
            return;
        }
        if (cur == null) {
            clearCurrent();
        } else {
            setCurrent(cur["d"], cur["since"]);
        }
    }

    // -- domain names ----------------------------------------------------

    function domains() {
        var d = App.Storage.getValue(KEY_DOMAINS);
        if (d == null || !(d instanceof Lang.Array) || d.size() == 0) {
            return DEFAULT_DOMAINS;
        }
        return d;
    }

    function setDomains(names) {
        App.Storage.setValue(KEY_DOMAINS, names);
    }

    function nameFor(idx) {
        var d = domains();
        if (idx == null || idx < 0 || idx >= d.size()) {
            return "?";
        }
        return d[idx];
    }
}
