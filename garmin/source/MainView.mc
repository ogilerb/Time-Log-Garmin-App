using Toybox.Graphics as Gfx;
using Toybox.Lang;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi as Ui;

// What is running, and for how long.
//
// Elapsed time is derived from the stored start timestamp rather than counted,
// so it stays correct across app restarts and does not drift.
class MainView extends Ui.View {

    hidden var _timer;

    function initialize() {
        View.initialize();
    }

    function onShow() {
        // Only ticks while the view is actually on screen; the app is opened for
        // a few seconds at a time so this costs nothing.
        _timer = new Timer.Timer();
        _timer.start(method(:onTick), 1000, true);
    }

    function onHide() {
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
        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var cx = w / 2;
        var cy = dc.getHeight() / 2;

        var cur = Log.current();

        if (cur == null) {
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
            dc.drawText(cx, cy - 42, Gfx.FONT_SMALL, Log.nameFor(cur),
                        Gfx.TEXT_JUSTIFY_CENTER);

            dc.setColor(Gfx.COLOR_GREEN, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy - 8, Gfx.FONT_NUMBER_MEDIUM,
                        formatElapsed(Log.now() - Log.since()),
                        Gfx.TEXT_JUSTIFY_CENTER);
        }

        drawStatus(dc, cx, cy);
    }

    // Bottom line: unsent presses, or a warning that settings are missing. Both
    // are silent failures otherwise -- the watch would look like it was working.
    hidden function drawStatus(dc, cx, cy) {
        var text = null;
        var colour = Gfx.COLOR_LT_GRAY;

        if (!Net.configured()) {
            text = "Set server in app settings";
            colour = Gfx.COLOR_RED;
        } else {
            var n = Log.pending();
            if (n == 1) {
                text = "1 press unsent";
                colour = Gfx.COLOR_YELLOW;
            } else if (n > 1) {
                text = n.toString() + " presses unsent";
                colour = Gfx.COLOR_YELLOW;
            }
        }

        if (text != null) {
            dc.setColor(colour, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy + 58, Gfx.FONT_XTINY, text, Gfx.TEXT_JUSTIFY_CENTER);
        }
    }
}
