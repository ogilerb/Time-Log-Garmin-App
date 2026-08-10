using Toybox.Graphics as Gfx;
using Toybox.Lang;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi as Ui;

// Ceiling on how long the snapshot below may go unrefreshed while the clock is
// ticking. Only reached if a tick and an unrelated requestUpdate coalesce into a
// single frame; the ordinary path reloads on the spot.
const RELOAD_BACKSTOP_SEC = 10;


// What is running, and for how long.
//
// Elapsed time is derived from the stored start timestamp rather than counted,
// so it stays correct across app restarts and does not drift.
class MainView extends Ui.View {

    hidden var _timer;
    hidden var _shown = false;

    // Snapshot of the stored state this view draws. Reading it per frame meant
    // six storage and property lookups every second for as long as the app sat
    // on screen, so it is reloaded on the redraws that follow a state change
    // instead. A tick is not one of those: it only advances the elapsed clock,
    // which is arithmetic on _since and touches no storage at all.
    hidden var _cur;
    hidden var _since;
    hidden var _name;
    hidden var _configured;
    hidden var _pending;

    hidden var _fromTick = false;
    hidden var _loadedAt = 0;

    function initialize() {
        View.initialize();
        // Populated before the first draw; onShow refreshes it again anyway.
        reload();
    }

    function onShow() {
        _shown = true;
        reload();
        applyTimer();
    }

    function onHide() {
        _shown = false;
        stopTimer();
    }

    // -- snapshot ---------------------------------------------------------

    hidden function reload() {
        _cur        = Log.current();
        _since      = Log.since();
        _name       = (_cur == null) ? null : Log.nameFor(_cur);
        _configured = Net.configured();
        _pending    = Log.pending();
        _loadedAt   = Log.now();
    }

    // -- tick -------------------------------------------------------------

    // The elapsed clock is the only thing on this screen that changes on its
    // own, so the timer runs only while something is being tracked. Idle, the
    // screen is static text and a 1Hz redraw would spend battery drawing
    // identical pixels.
    hidden function applyTimer() {
        if (!_shown || _cur == null) {
            stopTimer();
        } else {
            startTimer();
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
        _timer.start(method(:onTick), 1000, true);
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
        _fromTick = true;
        Ui.requestUpdate();
    }

    // -- drawing ----------------------------------------------------------

    hidden function formatElapsed(seconds) {
        if (seconds < 0) { seconds = 0; }
        var h = seconds / 3600;
        var m = (seconds % 3600) / 60;
        var s = seconds % 60;
        return Lang.format("$1$:$2$:$3$", [
            h.format("%d"), m.format("%02d"), s.format("%02d")
        ]);
    }

    function onUpdate(dc) {
        var t = Log.now();

        // Anything that is not our own tick got here through a requestUpdate
        // raised by a callback that changed stored state -- new domain names, a
        // sync ack, background data, changed settings -- so the snapshot is
        // stale and gets reloaded. No caller needs to know that; asking for a
        // redraw is enough.
        if (!_fromTick || t - _loadedAt >= RELOAD_BACKSTOP_SEC) {
            reload();
            applyTimer();
        }
        _fromTick = false;

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
        } else {
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy - 62, Gfx.FONT_XTINY, "TRACKING",
                        Gfx.TEXT_JUSTIFY_CENTER);

            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy - 42, Gfx.FONT_SMALL, _name,
                        Gfx.TEXT_JUSTIFY_CENTER);

            dc.setColor(Gfx.COLOR_GREEN, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy - 8, Gfx.FONT_NUMBER_MEDIUM,
                        formatElapsed(t - _since),
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
