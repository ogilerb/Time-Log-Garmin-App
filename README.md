# Garmin fenix 6 → Google Calendar time logger

Press a button on the watch, and it closes whatever event was running and opens a
new one on the Google Calendar for that life domain. Your calendar becomes a
passive record of where your time actually went.

Seven domains, in the order the watch sends them:

| # | Calendar event title | Watch label |
|---|---|---|
| 0 | Compounding | Compounding |
| 1 | Enriching | Enriching |
| 2 | Essential | Essential |
| 3 | Professional, Other-Directed | Prof: Other |
| 4 | Professional, Self-Directed | Prof: Self |
| 5 | Unfocused/Idling/Unactivated | Unfocused |
| 6 | Waste | Waste |

Tracking stops only when you explicitly pick **Stop tracking**. Nothing is
auto-closed.

---

## How often do I have to redo the Google auth?

**Once.** Then effectively never.

You run `authorize.py` one time on your Mac, click "Allow" in the browser, and it
writes `token.json` containing a refresh token. You copy that one file to the
Oracle server. From then on the server mints its own access tokens forever — it
never needs a browser, and **your Mac is not part of the running system**. The
live data path is `watch → phone → Oracle server → Google`.

Google refresh tokens do not expire on a timer. Yours only dies if:

- **The OAuth consent screen is left in "Testing" status.** Google force-expires
  refresh tokens after **7 days** in that state. This is the one people actually
  hit. Set the consent screen to **In production** — for a single-user app on your
  own account this needs no verification review.
- You revoke access at [myaccount.google.com/permissions](https://myaccount.google.com/permissions).
- It goes six months completely unused.

If it ever does break, recovery is: re-run `authorize.py` on any machine with a
browser, `scp` the new `token.json` over, `systemctl restart timelog`.

---

## Architecture

```
fenix 6 watch-app  ──BLE──▶  phone  ──HTTPS──▶  Oracle server  ──▶  Google Calendar
```

The watch is deliberately dumb. It emits an append-only log of presses
`(id, action, domain, timestamp)` and never sees a Google credential. The server
owns all calendar state, which is what makes retries safe.

This split is not a preference — it is forced by the platform:

- **Google blocks OAuth in embedded webviews** (`disallowed_useragent`), and
  Garmin Connect Mobile's OAuth browser is exactly that. On-watch Google auth is
  a dead end.
- **Google Apps Script is unusable as an endpoint**: it 302-redirects to
  `script.googleusercontent.com`, and Connect IQ re-issues the request to the
  redirect target *with the POST body dropped*.
- **Connect IQ requires a CA-signed HTTPS certificate.** Self-signed fails
  silently, which is why this sits behind your existing domain.

### Why presses carry ids

The watch may resend a batch whose response was lost in flight. Without
deduplication that duplicates every event in it. Each press carries a monotonic
id; the server remembers the last 500 applied and skips repeats. The id counter
is seeded from the clock rather than from zero, so reinstalling the app cannot
produce ids the server has already burned.

### Layout

```
garmin/                     Connect IQ watch app (Monkey C)
  source/
    TimeLogApp.mc           App entry point + background wakeup scheduling
    MainView.mc             "what's running, for how long" screen
    MainDelegate.mc         Button handling and the domain menu
    Log.mc                  Durable press queue in Application.Storage
    Sync.mc                 HTTP to the server (SyncJob, DomainsJob)
    BgService.mc            Drains the queue while the app is closed
  resources/settings/       Server URL + auth token properties
  manifest.xml              Device targets and permissions

server/                     FastAPI service (Python 3.9+)
  app.py                    The two endpoints, and press replay
  state.py                  SQLite: open event + applied-id set
  calendar_client.py        Google Calendar wrapper, silent token refresh
  authorize.py              One-time OAuth, run on a machine with a browser
  list_calendars.py         Prints calendar ids for config.yaml
  config.example.yaml       Template -> copy to config.yaml
  deploy.sh                 Idempotent deploy to the server
  timelog.service           systemd unit
  deploy/                   nginx and Caddy reverse-proxy snippets
  requirements-dev.txt      Test-only deps; never installed on the server
  test_replay.py            Replay/idempotency tests, no network
  simulate_watch.py         Pretend to be the watch
  verify_e2e.py             Full-path check against the live server
```

### Secrets

Nothing sensitive is tracked. `.gitignore` excludes all of it:

| Not in the repo | What it is |
|---|---|
| `server/credentials.json` | Google OAuth client |
| `server/token.json` | Refresh token — full calendar access |
| `server/config.yaml` | Your real calendar ids |
| `server/*.db` | Runtime state |
| `garmin/developer_key*` | Signs your watch builds |
| `garmin/garmin-settings.json` | Build output; carries the auth token |

The shared secret between watch and server lives only in `/etc/timelog.env` on
the server, generated by `deploy.sh` on first run. `properties.xml` ships with
empty placeholders — see [step 6](#6-watch--settings) before you fill them in.

---

## Setup

### 1. Google (once, on the Mac)

Two Console steps, both required — skipping either fails in a confusing way
later rather than immediately:

1. **Enable the Google Calendar API** on the project, at
   [console.cloud.google.com/apis/library/calendar-json.googleapis.com](https://console.cloud.google.com/apis/library/calendar-json.googleapis.com).
   Without it, authorization succeeds and then every calendar write returns 403.
2. **Set the OAuth consent screen to "In production."** In *Testing* status Google
   expires refresh tokens after 7 days, so logging works for a week and then
   stops silently.

Then create a **Desktop app** OAuth client and download it to
`server/credentials.json`. Desktop is the right type here (`installed`, redirect
`http://localhost`); a Web client will not work with `authorize.py`. If you
already have a Desktop client from another project you can reuse it — an OAuth
client is just an app identity — but do steps 1 and 2 on whichever project it
belongs to.

```bash
cd server
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

# Put the downloaded OAuth client here:
#   server/credentials.json

.venv/bin/python authorize.py          # browser opens; click Allow
```

**Always use `.venv/bin/python`, not a bare `python3`.** The dependencies are
installed only in the venv; a system or Homebrew Python fails with
`ModuleNotFoundError: No module named 'google_auth_oauthlib'`.

### 2. Calendar IDs (locally, before deploying)

```bash
cd server
cp config.example.yaml config.yaml
.venv/bin/python list_calendars.py
```

`list_calendars.py` matches your calendars to the domains by name and prints a
ready-to-paste `domains:` block; paste it over the one in `config.yaml`. Anything
it cannot match by name is left as `FILL_ME` with the full calendar list printed
above it, so you can pick the id by hand.

`config.yaml` is **gitignored** — calendar ids identify your account's private
calendars, so only the placeholder `config.example.yaml` is tracked. Edit the
domain names and `timezone:` there too if you want different ones; the list in
this README is just what the example ships with.

### 3. Server (on the Oracle box)

```bash
cd server
./deploy.sh ubuntu@your-server
```

Idempotent — this is also how you ship every later change. It creates the
`timelog` service user, syncs the code, builds the venv, installs the systemd
unit, starts the service, and health-checks it. On success it prints the auth
token to enter on the watch.

The shared secret is generated on the first run and preserved on every run after
that, since regenerating it would silently break the watch.

`credentials.json` is deliberately **not** copied. `token.json` already contains
the client id, secret and refresh token, so the interactive OAuth client file has
no reason to sit on a public server.

**Server notes**: Ubuntu 20.04's system Python is 3.8, which predates `zoneinfo`.
`deploy.sh` installs **python3.9** alongside it (3.9 is the newest with a `-venv`
package on focal/arm64 — deadsnakes has no `python3.1x-venv` for this
architecture). The code is written to that floor, so it avoids `X | None` union
syntax. The system `/usr/bin/python3` is never touched.

### 3b. Public HTTPS — Tailscale Funnel

Connect IQ needs a CA-signed certificate, and Let's Encrypt will not issue one
for a bare IP. This box has no domain and only port 25565 open, so Funnel is used:
it connects **outbound only**, needs no ports opened and no DNS, and supplies a
real Let's Encrypt certificate.

```bash
curl -fsSL https://tailscale.com/install.sh | sudo sh
sudo tailscale up --hostname=timelog
# visit the printed login URL, then the funnel-enable URL it prints next
sudo tailscale funnel --bg 8099
```

Funnel then serves the box at `https://timelog.<your-tailnet>.ts.net`, which it
prints on success. That hostname is **public internet-reachable** — the auth
token is the only thing in front of it, so treat both as secrets and keep them
out of the repo.

Funnel proxies the root straight to `127.0.0.1:8099`, so there is **no path
prefix** — the watch's Server URL is the bare hostname, and endpoints are
`/v1/events` and `/v1/domains`. Only port 8099 is exposed; SSH, Docker containers
and everything else stay private on the tailnet.

To revoke public access instantly: `sudo tailscale funnel --https=443 off`.

If you later buy a domain, `server/deploy/` has ready nginx and Caddy snippets;
switching is just a change to the watch's Server URL setting.

```bash
journalctl -u timelog -f    # watch it work
```

`timezone:` in `config.yaml` (`America/Vancouver` in the example) is the only
place the clock is configured. The watch only ever sends UTC epoch seconds and
the server does the conversion, so DST changes and travel need no special
handling — events always land at the wall-clock time you pressed the button.

### 4. Watch — toolchain

1. Install a **JDK** (any recent one), then the
   [Connect IQ SDK Manager](https://developer.garmin.com/connect-iq/sdk/) for macOS.
2. In SDK Manager: install an SDK supporting **API level 3.4** (9.2.0 works), and
   under Devices tick **fēnix 6 Pro** — that entry covers the fēnix 6 Sapphire.
3. In VS Code install Garmin's **Monkey C** extension.
4. **Open the `garmin/` folder as the VS Code workspace root**, not the project
   root. The extension looks for `monkey.jungle` at the top level and will not
   find the project otherwise.
5. Generate a developer key — `Cmd+Shift+P` → **Monkey C: Generate a Developer
   Key**, or by hand:

```bash
cd garmin
openssl genrsa -out developer_key.pem 4096
openssl pkcs8 -topk8 -inform PEM -outform DER \
  -in developer_key.pem -out developer_key -nocrypt
```

The build below passes `-y ./developer_key`, so the DER output is named to match.
Both files are gitignored (`developer_key*`) — the key signs your builds and
never belongs in the repo.

### 5. Watch — build and sideload

Try it in the simulator first (`Cmd+Shift+P` → **Monkey C: Run App**, or `F5`).
The simulator has real network access through the Mac, so it will talk to your
live server.

Build a `.prg` with `Cmd+Shift+P` → **Monkey C: Build for Device**, or from the
command line (this is the exact invocation that is known to work):

```bash
cd garmin
SDK=~/Library/Application\ Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.2.0-2026-06-09-92a1605b2
java -jar "$SDK/bin/monkeybrains.jar" \
  -o ./garmin.prg -f ./monkey.jungle -y ./developer_key -d fenix6pro -w -r
```

**Build target is `fenix6pro`** — the Sapphire editions are Pro-class units.
Garmin groups them as *"fēnix 6 Pro / 6 Sapphire / 6 Pro Solar / 6 Pro Dual
Power / quatix 6"*. The plain `fenix6` id covers only the base *"fēnix 6 / 6
Solar / 6 Dual Power"*.

| Your watch | Device id |
|---|---|
| **fēnix 6 Sapphire** / 6 Pro / 6 Pro Solar | **`fenix6pro`** |
| fēnix 6 (base) / 6 Solar | `fenix6` |
| fēnix 6S Sapphire / 6S Pro | `fenix6spro` |
| fēnix 6S (base) | `fenix6s` |
| fēnix 6X Pro / 6X Sapphire / 6X Pro Solar | `fenix6xpro` |

`manifest.xml` declares only `fenix6pro`. To support another variant, add its
`<iq:product>` **and** download that device's files in SDK Manager — an id whose
device files are missing produces "Invalid device id" warnings and builds nothing
for it.

**Getting it onto the watch from a Mac.** The fenix 6 connects as an **MTP**
device, and macOS does not mount MTP in Finder — the watch will never appear as a
drive.

Google **discontinued Android File Transfer in May 2024** and its download page is
gone; it also never ran natively on Apple Silicon. Use **OpenMTP** instead — free,
open source, native arm64:

<https://github.com/ganeshrvel/openmtp/releases>

1. Install OpenMTP (arm64 `.dmg`). On first launch, right-click → **Open** to get
   past Gatekeeper, since it is not notarized by Apple.
2. **Quit Garmin Express first.** Both want exclusive MTP access and conflict;
   only one can run at a time.
3. Plug the watch in. OpenMTP shows the device in its right-hand pane.
4. Copy `garmin.prg` into **`GARMIN/APPS/`**.
5. Eject, unplug. The app appears in the watch's app list.

Before installing anything, check the watch for **USB Drive Mode** in its system
settings — it makes the watch mount as ordinary mass storage in Finder, no extra
software needed. It appears only on some *non-Pro* variants, and a Sapphire is
Pro-class, so do not count on it.

To update the app later, overwrite the same `.prg` and restart the app.

### 6. Watch — settings

Set **Server URL** and **Auth token** in the app's settings in Garmin Connect
Mobile. With Tailscale Funnel the URL is the bare hostname
(`https://timelog.your-tailnet.ts.net`, no path); behind the nginx or Caddy
snippets it is `https://your.domain/timelog`. The token is the one `deploy.sh`
printed.

If the settings do not stick — Garmin Connect Mobile is unreliable about this for
sideloaded apps — put them in `garmin/resources/settings/properties.xml` and
rebuild. That path always works. The main screen shows a red "Set server in app
settings" warning until both are present, so this failure is never silent.

> Those two properties ship **empty**, and filling them in bakes a live secret
> into the file. Before you edit it:
>
> ```bash
> git update-index --skip-worktree garmin/resources/settings/properties.xml
> ```
>
> That keeps your filled-in copy out of every commit while leaving the
> placeholder version in the repo. The SDK also writes the token into
> `garmin/garmin-settings.json`, which `.gitignore` already excludes.

---

## Verifying

Work bottom-up so a failure is unambiguous about which layer broke.

```bash
cd server
export TIMELOG_URL=https://timelog.your-tailnet.ts.net
export TIMELOG_TOKEN_SECRET=...          # from /etc/timelog.env on the server

# 0. The whole path at once: public HTTPS -> auth -> replay -> Google Calendar,
#    including the duplicate-prevention guarantee. Cleans up after itself, so it
#    is safe to run against the real calendars.
.venv/bin/python verify_e2e.py 6

# 1. Replay + idempotency logic, no network, no Google.
#    Needs the test-only deps, which requirements.txt deliberately omits so they
#    never get installed on the server:
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest test_replay.py -v

# 2. Real calendar writes. Run from the server itself, where the API is bound to
#    localhost -- or keep the public URL above and run it from anywhere.
export TIMELOG_URL=http://127.0.0.1:8099
.venv/bin/python simulate_watch.py domains
.venv/bin/python simulate_watch.py start 0 -3600   # started an hour ago
.venv/bin/python simulate_watch.py start 6         # switch: closes the previous
.venv/bin/python simulate_watch.py stop
#   -> check Google Calendar: one 1h Compounding block, then a Waste block

# 3. The duplicate-prevention guarantee
.venv/bin/python simulate_watch.py replay          # must NOT create a second event

# 4. Public TLS, from the Mac. Connect IQ is stricter than curl -- any warning
#    here means the watch will fail silently.
curl -v "https://timelog.your-tailnet.ts.net/v1/domains" \
  -H "Authorization: Bearer $TIMELOG_TOKEN_SECRET"
```

Then in the Connect IQ simulator (it has real network access via the Mac): walk
the menu, pick a domain, and confirm both the server log and Google Calendar.
Disable the phone connection in the simulator, make three presses, re-enable, and
confirm all three replay in order into correctly adjacent events.

Finally sideload, walk away from your phone, log a couple of switches, come back,
and confirm the queue drains within ~5 minutes (the shortest wakeup interval
Connect IQ allows).

**Use a scratch calendar for all of this, not your real seven.**

---

## Things worth knowing

- **`Time.Moment.value()` must return UNIX epoch seconds.** If it ever returns a
  Garmin-epoch value instead, the server's plausibility guard rejects the press
  and logs it loudly rather than writing events into 1989. Watch the first sync's
  server log to confirm.
- **The background service only works with the phone in range.** Out of range it
  fails with `-104` and leaves the queue intact; this is expected, not a bug.
- **The Sapphire's Wi-Fi does not help.** Connect IQ has no API to route
  `makeWebRequest` over the watch's own Wi-Fi — it only reaches the internet
  through Garmin Connect Mobile over Bluetooth. Wi-Fi is used for Garmin's own
  syncs and firmware updates, not for app traffic. Phone-free logging is not
  possible; that is exactly what the offline queue exists to paper over.
- **The wakeup is registered only while presses are queued** and removed once it
  drains, so the watch is not woken every five minutes forever.
- **Never reorder `domains:` in `config.yaml`.** The index is the wire format;
  reordering misfiles any presses still queued on the watch. Append only.
- **`minApiLevel` must be a three-part version.** `3.4` fails manifest schema
  validation; it has to be `3.4.0`. The error is a raw regex complaint about
  `versionInfo` and does not say which attribute is at fault.
- **The background process gets 32KB; the app gets 1.25MB** on this device. Code
  reachable from the background service is marked `(:background)` so the UI is
  excluded from that image. If you add code the service calls, annotate it too —
  otherwise the compiler warns that the *entire* app is loaded in the background,
  which risks blowing the 32KB ceiling.
- The remaining "Cannot determine if container access is using container type"
  build warnings are Monkey Types noise from indexing values read back out of
  `Application.Storage`, which is untyped by nature. They are harmless.
- A running event is created with a 1-minute placeholder end (Google rejects
  `end <= start`) and stretched to the true time on each sync, so an in-progress
  block shows its real length.
