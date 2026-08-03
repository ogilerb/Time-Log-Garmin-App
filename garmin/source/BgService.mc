using Toybox.Background;
using Toybox.Lang;
using Toybox.System;

// Drains the press queue while the app is closed.
//
// This runs in a separate, much more memory-constrained process than the app,
// which is why the server's responses use single-letter keys -- the response and
// the dictionary built from it must both fit here at once.
//
// It only succeeds when the phone is in Bluetooth range. When it is not, the
// request fails with -104 and the queue is simply left for the next wakeup.
(:background)
class BgService extends System.ServiceDelegate {

    // Held as a member, not a local: a job dropped on the floor can be collected
    // while its web request is still in flight, and the callback never fires.
    hidden var _job;

    function initialize() {
        ServiceDelegate.initialize();
    }

    function onTemporalEvent() {
        if (Log.pending() == 0) {
            Background.exit(false);
            return;
        }
        // SyncJob writes acks and the reconciled current domain straight into
        // Application.Storage, which the foreground app shares. Nothing needs to
        // cross the process boundary except a nudge to redraw -- which is why
        // this exits with a plain boolean rather than the server payload.
        _job = new SyncJob(method(:onDone));
        _job.start();
    }

    // A background process that never calls Background.exit() is killed on
    // timeout and its work is thrown away, so both paths must exit.
    function onDone(ok) {
        Background.exit(ok);
    }
}
