using Toybox.Lang;
using Toybox.System;
using Toybox.WatchUi as Ui;

// Sentinel id for the "Stop tracking" row, kept out of the 0..n domain range.
const MENU_ID_STOP = -1;


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
    function onSelect(item) as Void {
        var id = item.getId();

        // Record first, send second. The press is durable the moment this
        // returns, whether or not the phone is anywhere nearby.
        if (id == MENU_ID_STOP) {
            Log.push("stop", null);
            Log.clearCurrent();
        } else {
            var entry = Log.push("start", id);
            Log.setCurrent(id, entry["t"]);
        }

        // Fire and forget; the queue and the background service handle failure.
        // Parked in Net.inflight so popping this view below cannot collect the
        // job before its response lands.
        Net.inflight = new SyncJob(method(:onSynced));
        Net.inflight.start();
        Bg.sync();

        Ui.popView(Ui.SLIDE_DOWN);
    }

    function onSynced(ok) {
        Bg.sync();
        Ui.requestUpdate();
    }

    function onBack() as Void {
        Ui.popView(Ui.SLIDE_DOWN);
    }
}
