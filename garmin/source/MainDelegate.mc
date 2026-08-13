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

    // The rows coarsen as they go back: every 5 minutes for the first hour,
    // every 15 out to four hours, every half hour out to twelve.
    //
    // Resolution is spent where memory actually has it. You know a switch was
    // "about twenty minutes ago" to the minute; seven hours back you do not, and
    // a row per five minutes there would only be 84 more things to scroll past.
    // A flat 5-minute list to twelve hours would be 145 rows; this is 41.
    //
    // Parallel arrays, same index in both: STEPS[b] is the gap between rows for
    // every offset below BAND_ENDS[b].
    const STEPS     = [ 300,   900,  1800];
    const BAND_ENDS = [3600, 14400, 43200];

    // The furthest back any row reaches, and the only place twelve hours is
    // written down -- deriving it means the cap cannot drift from the bands.
    function cap() {
        return BAND_ENDS[BAND_ENDS.size() - 1];
    }

    // Gap between `off` and the next row after it, or 0 once past the last band.
    function stepAfter(off) {
        for (var b = 0; b < BAND_ENDS.size(); b += 1) {
            if (off < BAND_ENDS[b]) {
                return STEPS[b];
            }
        }
        return 0;
    }

    // How far back a press may reach.
    //
    // A boundary placed before the start of the event it closes would leave two
    // overlapping events in the calendar, so the running block's own length is
    // the ceiling. The server clamps this as well -- its idea of what is open is
    // the authoritative one -- but offering a choice that will not be honoured
    // is worse than not offering it.
    //
    // This is also what keeps the menu short in practice: forty minutes into a
    // block there is only room for eight rows, and the full 41 appear only when
    // something has genuinely been running half a day.
    function limit() {
        if (Log.current() == null) {
            return cap();
        }
        var room = Log.now() - Log.since() - MIN_BLOCK_SEC;
        if (room < 0) {
            return 0;
        }
        return (room > cap()) ? cap() : room;
    }

    // Built rather than stored: generating the labels costs less code than
    // spelling out 41 of them, and none of it survives the menu closing.
    function label(sec) {
        if (sec == 0) {
            return "Now";
        }
        var h = sec / 3600;
        var m = (sec % 3600) / 60;
        if (h == 0) {
            return Lang.format("$1$ min ago", [m.format("%d")]);
        }
        if (m == 0) {
            return Lang.format("$1$h ago", [h.format("%d")]);
        }
        return Lang.format("$1$h $2$m ago", [h.format("%d"), m.format("%d")]);
    }

    // Only the offsets that fit in the room above. "Now" always fits, so the
    // menu is never empty.
    function menu() {
        var m = new Ui.Menu2({:title => "How long ago?"});
        var max = limit();
        var off = 0;
        while (off <= max) {
            m.addItem(new Ui.MenuItem(label(off), null, off, {}));
            var step = stepAfter(off);
            if (step == 0) {
                break;
            }
            off += step;
        }
        return m;
    }
}


class MainDelegate extends Ui.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
        // Only once the cached names have aged out. This used to run on every
        // single open, putting a Bluetooth round trip behind a button whose
        // whole point is being cheap to press -- and the answer was all but
        // always the list already held.
        if (Log.domainsStale()) {
            Net.inflight = new DomainsJob(method(:onDomains));
            Net.inflight.start();
        }
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

        // The errand is done, so the view underneath winds the app up shortly
        // after it reappears rather than sitting in the foreground.
        justLogged = true;

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
