using Toybox.Lang;
using Toybox.System;
using Toybox.WatchUi as Ui;

// Sentinel id for the "Stop tracking" row, kept out of the 0..n domain range.
const MENU_ID_STOP = -1;

// Shortest block the calendar will hold, mirroring MIN_EVENT_SECONDS on the
// server. Google rejects an event whose end is not after its start.
const MIN_BLOCK_SEC = 60;


// Second step of a press: how long ago the switch actually happened.
//
// This exists for the 11:00 realisation that you stopped Compounding at 10:00
// and never said so. Backdating puts the boundary where it belongs instead of
// donating the hour to whatever was still running.
module Backdate {

    // Offsets in seconds, and what the menu calls them. Same index in both.
    const OFFSETS = [0, 300, 600, 900, 1800, 2700, 3600, 7200];
    const LABELS = [
        "Now",
        "5 min ago",
        "10 min ago",
        "15 min ago",
        "30 min ago",
        "45 min ago",
        "1 hour ago",
        "2 hours ago"
    ];

    // How far back a press may reach.
    //
    // A boundary placed before the start of the event it closes would leave two
    // overlapping events in the calendar, so the running block's own length is
    // the ceiling. The server clamps this as well -- its idea of what is open is
    // the authoritative one -- but offering a choice that will not be honoured
    // is worse than not offering it.
    function limit() {
        if (Log.current() == null) {
            return OFFSETS[OFFSETS.size() - 1];
        }
        var room = Log.now() - Log.since() - MIN_BLOCK_SEC;
        return (room < 0) ? 0 : room;
    }

    // Only the offsets that fit in that room. "Now" always fits, so the menu is
    // never empty.
    function menu() {
        var m = new Ui.Menu2({:title => "How long ago?"});
        var max = limit();
        for (var i = 0; i < OFFSETS.size(); i += 1) {
            if (OFFSETS[i] <= max) {
                m.addItem(new Ui.MenuItem(LABELS[i], null, OFFSETS[i], {}));
            }
        }
        return m;
    }
}


class MainDelegate extends Ui.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
        // Refresh names and repair local state on open. Cheap, and it means a
        // domain renamed on the server shows up without touching the watch.
        Net.inflight = new DomainsJob(method(:onDomains));
        Net.inflight.start();
    }

    function onDomains(ok) {
        if (ok) {
            Ui.requestUpdate();
        }
    }

    // START on the fenix 6.
    function onSelect() {
        var menu = new Ui.Menu2({:title => "Log time"});
        var names = Log.domains();
        for (var i = 0; i < names.size(); i += 1) {
            menu.addItem(new Ui.MenuItem(names[i], null, i, {}));
        }
        if (Log.current() != null) {
            menu.addItem(new Ui.MenuItem("Stop tracking", null, MENU_ID_STOP, {}));
        }
        Ui.pushView(menu, new DomainMenuDelegate(), Ui.SLIDE_UP);
        return true;
    }
}


class DomainMenuDelegate extends Ui.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    // Menu2InputDelegate.onSelect returns Void, unlike BehaviorDelegate.onSelect
    // above which returns Boolean.
    //
    // Nothing is recorded here: the press is only half chosen until the backdate
    // menu supplies the other half. Backing out of that menu returns to this one
    // with no trace left behind.
    function onSelect(item) as Void {
        Ui.pushView(Backdate.menu(),
                    new BackdateMenuDelegate(item.getId()),
                    Ui.SLIDE_LEFT);
    }

    function onBack() as Void {
        Ui.popView(Ui.SLIDE_DOWN);
    }
}


// Commits the press once both halves -- what, and when -- are known.
class BackdateMenuDelegate extends Ui.Menu2InputDelegate {

    hidden var _id;   // domain index, or MENU_ID_STOP

    function initialize(id) {
        Menu2InputDelegate.initialize();
        _id = id;
    }

    function onSelect(item) as Void {
        var offset = item.getId() as Lang.Number;
        var ts = Log.now() - offset;

        // Record first, send second. The press is durable the moment this
        // returns, whether or not the phone is anywhere nearby.
        if (_id == MENU_ID_STOP) {
            Log.push("stop", null, ts);
            Log.clearCurrent();
        } else {
            Log.push("start", _id, ts);
            Log.setCurrent(_id, ts);
        }

        // Fire and forget; the queue and the background service handle failure.
        // Parked in Net.inflight so popping this view below cannot collect the
        // job before its response lands.
        Net.inflight = new SyncJob(method(:onSynced));
        Net.inflight.start();
        Bg.sync();

        // Both menus go: the domain list underneath has served its purpose, and
        // landing back on it would invite an immediate contradictory press.
        Ui.popView(Ui.SLIDE_IMMEDIATE);
        Ui.popView(Ui.SLIDE_DOWN);
    }

    function onSynced(ok) {
        Bg.sync();
        Ui.requestUpdate();
    }

    function onBack() as Void {
        Ui.popView(Ui.SLIDE_RIGHT);
    }
}
