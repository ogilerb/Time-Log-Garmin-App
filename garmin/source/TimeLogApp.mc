using Toybox.Application as App;
using Toybox.Background;
using Toybox.Lang;
using Toybox.System;
using Toybox.Time;
using Toybox.WatchUi as Ui;

// Five minutes is the shortest interval Connect IQ permits for a temporal event.
const SYNC_INTERVAL_SEC = 300;


// Background scheduling.
//
// The wakeup is registered only while presses are actually waiting, and torn
// down as soon as the queue drains. Leaving it registered permanently would wake
// the watch every five minutes forever for no reason, which is a real battery
// cost on a device people wear for two weeks per charge.
(:background)
module Bg {

    function registered() {
        return Background.getTemporalEventRegisteredTime() != null;
    }

    function sync() {
        if (Log.pending() > 0) {
            if (!registered()) {
                Background.registerForTemporalEvent(new Time.Duration(SYNC_INTERVAL_SEC));
                System.println("bg: registered");
            }
        } else if (registered()) {
            Background.deleteTemporalEvent();
            System.println("bg: deregistered");
        }
    }
}


// The app class itself must be in the background image: the background process
// instantiates it to reach getServiceDelegate().
(:background)
class TimeLogApp extends App.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() {
        return [new MainView(), new MainDelegate()];
    }

    function getServiceDelegate() {
        return [new BgService()];
    }

    // The background service already applied acks and the reconciled current
    // domain to shared storage, so there is nothing to merge here -- only the
    // scheduling to re-evaluate now that the queue may have drained.
    function onBackgroundData(data) {
        Bg.sync();
        Ui.requestUpdate();
    }

    // Settings changed in Garmin Connect Mobile; the URL or token may now differ.
    function onSettingsChanged() {
        Ui.requestUpdate();
    }
}
