# pier

```
                              ⚓
                              |
   ~~~~~~~~~~~~~~~~~~~~~~~~~~~|~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                              |
        ___  _ ___ _ _        |       ╱|、
       | _ \(_) __| '_)       |      (˚ˎ 。7      ports docking
       |  _/| | _|| |         |       |、˜〵      19000-19999
       |_|  |_|___|_|         |       じしˍ,)ノ
                              |
   ~~~~~~~~~~~~~~~~~~~~~~~~~~~|~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

**A port broker and `.test` router for your Mac.** Ask for a name, get a
port. Open `http://<name>.test/` and it just works.

---

## Why this exists

Local development on a single machine has a quiet, persistent problem:
**ports.**

You run an app on `:3000`. A coworker's tutorial says `:3000`. Your bundler
defaults to `:3000`. A Docker container is already there. You pick `:3001`,
a teammate forks the repo and picks `:3002`, an agent spins up a third
service on `:3003`, and a week later nobody remembers what's on what.

The URLs are even worse:

- `http://localhost:3000/admin` — what app is this again?
- `http://localhost:5173/` — Vite, but for which project?
- Two browser tabs, one logged-in cookie state, both fighting over `localhost`.

Every developer eventually patches around this:

- `/etc/hosts` files with hand-edited entries that need `sudo` per change and
  don't support wildcards
- shell aliases that stop working when you bump a port
- abandoned `dnsmasq` configs from a tutorial in 2017
- mental gymnastics to remember which app is on which number

It gets worse when **AI agents** join the mix. An agent spawning services
needs a port. Two agents working in parallel need two ports — and they need
to not collide. They need a way to ask "give me a port" without reading the
output of `lsof` or guessing.

**pier solves this once.** One command says "I want a slot called
`roadcase-vixen`," you get back a port, and the URL
`http://roadcase-vixen.test/` routes to whatever you start on that port.
No DNS edits. No hosts file. No collisions. Idempotent — ask again, get the
same port. Idle slots auto-release after an hour so the pool never silts up.

---

## Install

Requirements: macOS, [Homebrew](https://brew.sh).

```bash
git clone <this repo> pier
cd pier
./install.sh        # copies pier to /usr/local/bin/pier
pier setup          # one-time onboarding: dnsmasq, /etc/resolver, pf, launchd
                    # prompts for sudo once
```

That's it. The daemon runs under launchd from now on, including across
reboots.

---

## Usage

### Get a port for a web app

```bash
$ pier new roadcase-vixen
19000
http://roadcase-vixen.test → 127.0.0.1:19000
```

Start your app on `19000` (most frameworks accept `PORT=19000` or `--port
19000`). Open `http://roadcase-vixen.test/` — you're in.

The port is yours until you `release` it or it sits idle for an hour with no
listener. Asking again returns the same port:

```bash
$ pier new roadcase-vixen
19000
```

### Get a port for something that doesn't need a URL

A database, a queue, a sidecar — anything that doesn't speak HTTP:

```bash
$ pier new mydb --no-url
19001
```

Same lifecycle, same liveness GC, no `.test` route created.

### See what's allocated

```bash
$ pier list
NAME                      PORT  URL                               ALIVE      AGE
roadcase-vixen           19000  http://roadcase-vixen.test        2s ago     11m
mydb                     19001  —                                 5s ago     11m
agent-scratchpad         19002  http://agent-scratchpad.test      3m ago     27m
```

`ALIVE` is "how long ago was something last listening on this port" — pier
probes every 60 seconds. `AGE` is how long since the slot was claimed.

### Free a slot

```bash
$ pier release roadcase-vixen
released roadcase-vixen (port 19000)
```

You usually don't need to. If your app stops and the port goes quiet for an
hour, pier reclaims it.

### Scriptable / agent-friendly

```bash
PORT=$(pier get roadcase-vixen)
my-server --port "$PORT"

# Or all-in-one:
PORT=$(pier new roadcase-vixen)
```

Every command supports `--json` for structured output:

```bash
$ pier new mydb --no-url --json
{"name": "mydb", "port": 19001, "url": false, "created_at": 1740000000, "last_alive_at": 1740000000}
```

---

## The model

| Concept              | What it means                                                              |
|----------------------|----------------------------------------------------------------------------|
| **Slot**             | A named reservation: `(name → port, url?, timestamps)`.                    |
| **Idempotent claim** | `pier new foo` always returns the same port until `foo` is released.       |
| **Liveness**         | A slot is "alive" if anything is listening on its port (TCP connect probe).|
| **Grace period**     | New slots are protected for 1h, so you can claim before starting your app. |
| **Auto-release**     | After 1h with no listener, pier reclaims the slot.                         |
| **Range**            | Ports `19000`–`19999`. Out of the way of common dev defaults.              |

---

## How it works

```
   Browser                       pier daemon                    Your app
   -------                       -----------                    --------

   GET / HTTP/1.1
   Host: roadcase-vixen.test       :7878  ── routes by Host ──→  :19000
        │                            ▲                              │
        │                            │                              │
     :80 (TCP)                       │                          (your code)
        │                            │
        ▼                            │
   ┌─────────────────────────────────┴───────────────────────┐
   │                  macOS networking                       │
   │                                                         │
   │  /etc/resolver/test  →  dnsmasq  →  *.test = 127.0.0.1  │
   │  /etc/pf.conf  →  rdr :80 → :7878                       │
   └─────────────────────────────────────────────────────────┘
```

**The pieces, in order:**

1. **DNS:** `/etc/resolver/test` tells macOS "for any `.test` lookup, ask
   the resolver at `127.0.0.1`." That resolver is `dnsmasq`, which answers
   every `*.test` query with `127.0.0.1`.
2. **Port redirect:** macOS won't let an unprivileged process bind `:80`. So
   pf (the built-in packet filter) redirects `:80 → :7878`. Sudo once, at
   setup. Persists across reboots via `/etc/pf.conf`.
3. **The proxy:** the pier daemon listens on `:7878`, reads the `Host:`
   header, looks up the slot, and bidirectionally pipes the connection to
   `127.0.0.1:<port>`. It's a TCP-level proxy, so it transparently handles
   HTTP, keep-alive, and WebSockets — the things modern dev servers
   actually need.
4. **State:** `~/.pier/state.json` holds the allocation table, guarded by
   `flock`. Safe under parallel writers (e.g. multiple agents).
5. **GC:** every 60s the daemon TCP-probes each slot. Listening → refresh
   `last_alive_at`. Quiet for over an hour (and outside the grace period)
   → released.

**No Go runtime, no Node, no Rust.** Just `/usr/bin/python3` and the stdlib.
The script is one file. Read it.

---

## Files pier creates

| Path                                                         | Purpose                                |
|--------------------------------------------------------------|----------------------------------------|
| `~/.pier/state.json`                                         | The allocation table.                  |
| `~/.pier/pier.log`                                           | Daemon stdout/stderr.                  |
| `~/.pier/setup.json`                                         | Marker that setup ran.                 |
| `~/Library/LaunchAgents/dev.pier.daemon.plist`               | Keeps the daemon alive.                |
| `/etc/resolver/test`                                         | Routes `.test` lookups to dnsmasq.     |
| `/etc/pf.anchors/dev.pier`                                   | The `:80 → :7878` redirect rule.       |
| `/etc/pf.conf` (appended)                                    | Loads the anchor at boot.              |
| `$(brew --prefix)/etc/dnsmasq.d/dev.pier.conf`               | The `*.test → 127.0.0.1` answer.       |

---

## Troubleshooting

**`pier list` shows my port but the URL gives "connection refused".**
The daemon is what serves `:80`. Check `tail -f ~/.pier/pier.log` and
`launchctl list | grep dev.pier`. Reload with `launchctl unload && load
~/Library/LaunchAgents/dev.pier.daemon.plist`.

**`http://foo.test/` resolves to the wrong IP / doesn't resolve.**
Check that `/etc/resolver/test` exists and contains `nameserver 127.0.0.1`,
and that dnsmasq is running (`brew services list`). Verify with:
```bash
dscacheutil -q host -a name foo.test    # should print 127.0.0.1
```
If macOS has cached an old answer: `sudo dscacheutil -flushcache`.

**`http://foo.test/` (no port) gives "connection refused" but `:7878`
works.** The pf redirect isn't loaded. `sudo pfctl -s nat | grep 7878`
should show the redirect rule. Reload with `sudo pfctl -f /etc/pf.conf -E`.
Re-running `pier setup` is always safe.

**`pier new` returns 502 Bad Gateway in the browser.** The slot exists, but
nothing is listening on the port yet. Start your app.

**Port range exhausted.** Run `pier list`, then `pier release` slots you
don't need. (1000 ports is a lot; if you're hitting this, something is
allocating in a loop.)

---

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/dev.pier.daemon.plist
rm ~/Library/LaunchAgents/dev.pier.daemon.plist
sudo rm /etc/resolver/test /etc/pf.anchors/dev.pier
# (optional) edit /etc/pf.conf and remove the two `dev.pier` lines
sudo pfctl -f /etc/pf.conf
brew services stop dnsmasq
rm "$(brew --prefix)/etc/dnsmasq.d/dev.pier.conf"
sudo rm /usr/local/bin/pier
rm -rf ~/.pier
```
