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
./install.sh        # symlinks /usr/local/bin/pier → ./pier
pier setup          # one-time onboarding: dnsmasq, /etc/resolver, launchd
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
   Host: roadcase-vixen.test         :80  ── routes by Host ──→  :19000
        │                             ▲                             │
        │                             │                             │
     :80 (TCP)                        │                         (your code)
        │                             │
        ▼                             │
   ┌──────────────────────────────────┴──────────────────────┐
   │                  macOS networking                       │
   │                                                         │
   │  /etc/resolver/test  →  dnsmasq  →  *.test = 127.0.0.1  │
   └─────────────────────────────────────────────────────────┘
```

**The pieces, in order:**

1. **DNS:** `/etc/resolver/test` tells macOS "for any `.test` lookup, ask
   the resolver at `127.0.0.1`." That resolver is `dnsmasq`, which answers
   every `*.test` query with `127.0.0.1`.
2. **The proxy:** the pier daemon binds `:80` directly (running as root via
   a system LaunchDaemon — it has to, because `:80` is privileged). It reads
   the `Host:` header, looks up the slot, and bidirectionally pipes the
   connection to `127.0.0.1:<port>`. It's a TCP-level proxy, so it
   transparently handles HTTP, keep-alive, and WebSockets — the things
   modern dev servers actually need.
3. **State:** `~/.pier/state.json` holds the allocation table, guarded by
   `flock`. Safe under parallel writers (e.g. multiple agents). The lock
   file is mode 0666 so the root daemon and the user CLI can both take it.
4. **GC:** every 60s the daemon TCP-probes each slot. Listening → refresh
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
| `/Library/LaunchDaemons/dev.pier.daemon.plist`               | Keeps the daemon (root) alive.         |
| `/etc/resolver/test`                                         | Routes `.test` lookups to dnsmasq.     |
| `$(brew --prefix)/etc/dnsmasq.d/dev.pier.conf`               | The `*.test → 127.0.0.1` answer.       |

---

## Troubleshooting

**`pier list` shows my port but the URL gives "connection refused".**
The daemon serves `:80`. Check `tail -f ~/.pier/pier.log` and
`sudo launchctl print system/dev.pier.daemon`. Reload with
`sudo launchctl bootout system/dev.pier.daemon && sudo launchctl bootstrap
system /Library/LaunchDaemons/dev.pier.daemon.plist`. Re-running
`pier setup` is always safe.

**`http://foo.test/` resolves to the wrong IP / doesn't resolve.**
Check that `/etc/resolver/test` exists and contains `nameserver 127.0.0.1`,
and that dnsmasq is running (`brew services list`). Verify with:
```bash
dscacheutil -q host -a name foo.test    # should print 127.0.0.1
```
If macOS has cached an old answer: `sudo dscacheutil -flushcache`.

**`pier new` returns 502 Bad Gateway in the browser.** The slot exists, but
nothing is listening on the port yet. Start your app.

**Port range exhausted.** Run `pier list`, then `pier release` slots you
don't need. (1000 ports is a lot; if you're hitting this, something is
allocating in a loop.)

---

## Uninstall

```bash
sudo launchctl bootout system/dev.pier.daemon || \
  sudo launchctl unload /Library/LaunchDaemons/dev.pier.daemon.plist
sudo rm /Library/LaunchDaemons/dev.pier.daemon.plist
sudo rm /etc/resolver/test
brew services stop dnsmasq
rm "$(brew --prefix)/etc/dnsmasq.d/dev.pier.conf"
sudo rm /usr/local/bin/pier
rm -rf ~/.pier
```
