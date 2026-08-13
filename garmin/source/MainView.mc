using Toybox.Graphics as Gfx;
using Toybox.Lang;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi as Ui;

// The elapsed figure is wanted only to within a few minutes, so it is drawn to
// the minute and refreshed once a minute.
//
// At 1/60th of the old rate the per-frame storage reads stopped being worth
// caching, which is why onUpdate below simply reloads: six lookups a minute is
// nothing, and it buys back a display that is never stale and a view with no
// invalidation rules to get wrong.
const TICK_MS = 60 * 1000;

// How long the app stays up with no input before closing itself.
//
// A foreground Connect IQ app holds the watch out of its low-power state however
// little it draws, so once the redraw rate is down here, not being in the
// foreground is the only saving left worth having.
const IDLE_EXIT_SEC = 30;

// The window after a press is committed, which is shorter because the errand is
// done. It is not zero: the sync fired on the way out needs room to land, both
// so the "unsent" line clears while it can still be seen, and so a press does
// not routinely fall through to a background wakeup five minutes later -- that
// would spend more battery than leaving early saves. If the phone is out of
// range the press is already durable and the retry happens anyway.
const POST_LOG_EXIT_SEC = 5;

// Set by a press that has just been committed and consumed by the view it
// returns to, which is the only place with the standing to close the app.
var justLogged = false;


// What is running, and roughly how long ago the last press was.
//
// Both figures are derived from stored timestamps rather than counted, so they
// stay correct across app restarts and do not drift.
class MainView extends Ui.View {

    hidden var _timer;
    hidden var _exitTimer;
    hidden var _shown = false;

    hidden var _cur;
    hidden var _since;
    hidden var _last;
    hidden var _name;
    hidden var _configured;
    hidden var _pending;

    function initialize() {
        View.initialize();
        // Populated before the first draw; onShow refreshes it again anyway.
        reload();
    }

    function onShow() {
        _shown = true;
        reload();
        applyTimer();
        armExit(justLogged ? POST_LOG_EXIT_SEC : IDLE_EXIT_SEC);
        justLogged = false;
    }

    function onHide() {
        _shown = false;
        stopTimer();
        // A menu is up, so the user is plainly still here. Closing the app out
        // from under a half-made choice would be worse than any battery it
        // saved; onShow arms the countdown again on the way back.
        disarmExit();
    }

    // -- closing ----------------------------------------------------------

    hidden function armExit(seconds) {
        disarmExit();
        _exitTimer = new Timer.Timer();
        _exitTimer.start(method(:onExitDue), seconds * 1000, false);
    }

    hidden function disarmExit() {
        if (_exitTimer != null) {
            _exitTimer.stop();
            _exitTimer = null;
        }
    }

    function onExitDue() as Void {
        System.exit();
    }

    // -- state ------------------------------------------------------------

    hidden function reload() {
        _cur        = Log.current();
        _since      = Log.since();
        _last       = Log.lastPress();
        _name       = (_cur == null) ? null : Log.nameFor(_cur);
        _configured = Net.configured();
        _pending    = Log.pending();
    }

    // -- tick -------------------------------------------------------------

    // Runs only while something on screen actually ages. Before the first press
    // ever recorded there is no timestamp to count from, the display is fixed
    // text, and a tick would redraw identical pixels forever.
    hidden function applyTimer() {
        if (_shown && (_cur != null || _last > 0)) {
            startTimer();
        } else {
            stopTimer();
        }
    }

    hidden function startTimer() {
        // Never stack a second timer on top of a live one: two would double the
        // redraw rate with nothing to show for it, and only the newer could be
        // stopped again.
        if (_timer != null) {
            return;
        }
        _timer = new Timer.Timer();
        _timer.start(method(:onTick), TICK_MS, true);
    }

    hidden function stopTimer() {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
    }

    // Timer.start() requires a Method returning Void, so the annotation is load
    // bearing rather than decoration.
    function onTick() as Void {
        Ui.requestUpdate();
    }

    // -- drawing ----------------------------------------------------------

    // Minutes and hours only. Seconds were a precision the display could not
    // keep without a redraw every second, and that nothing here needs.
    hidden function formatCoarse(seconds) {
        if (seconds < 0) { seconds = 0; }
        var h = seconds / 3600;
        var m = (seconds % 3600) / 60;
        if (h == 0) {
            return Lang.format("$1$m", [m.format("%d")]);
        }
        return Lang.format("$1$h $2$m", [h.format("%d"), m.format("%02d")]);
    }

    function onUpdate(dc) {
        reload();
        applyTimer();

        var t = Log.now();

        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var cx = w / 2;
        var cy = dc.getHeight() / 2;

        if (_cur == null) {
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy - 40, Gfx.FONT_SMALL, "Not tracking",
                        Gfx.TEXT_JUSTIFY_CENTER);
            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy, Gfx.FONT_MEDIUM, "Press START",
                        Gfx.TEXT_JUSTIFY_CENTER);

            // Dates the stop, so an empty screen still says when it went empty.
            if (_last > 0) {
                dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
                dc.drawText(cx, cy + 34, Gfx.FONT_XTINY,
                            "last press " + formatCoarse(t - _last) + " ago",
                            Gfx.TEXT_JUSTIFY_CENTER);
            }
        } else {
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy - 62, Gfx.FONT_XTINY, "TRACKING",
                        Gfx.TEXT_JUSTIFY_CENTER);

            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy - 42, Gfx.FONT_SMALL, _name,
                        Gfx.TEXT_JUSTIFY_CENTER);

            dc.setColor(Gfx.COLOR_GREEN, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy - 8, Gfx.FONT_NUMBER_MEDIUM,
                        formatCoarse(t - _since),
                        Gfx.TEXT_JUSTIFY_CENTER);
        }

        drawStatus(dc, cx, cy);
    }

    // Bottom line: unsent presses, or a warning that settings are missing. Both
    // are silent failures otherwise -- the watch would look like it was working.
    hidden function drawStatus(dc, cx, cy) {
        var text = null;
        var colour = Gfx.COLOR_LT_GRAY;

        if (!_configured) {
            text = "Set server in app settings";
            colour = Gfx.COLOR_RED;
        } else if (_pending == 1) {
            text = "1 press unsent";
            colour = Gfx.COLOR_YELLOW;
        } else if (_pending > 1) {
            text = _pending.toString() + " presses unsent";
            colour = Gfx.COLOR_YELLOW;
        }

        if (text != null) {
            dc.setColor(colour, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy + 58, Gfx.FONT_XTINY, text, Gfx.TEXT_JUSTIFY_CENTER);
        }
    }
}
