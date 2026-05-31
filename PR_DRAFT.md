## Summary

Adds `slack` as a top-level pack alongside `discord` and `pr-review`.
After this lands, a city can wire Slack into its session graph by adding
one stanza to `city.toml` and provisioning a small env file — no gascity
binary changes required.

## What the pack provides

```
slack/
├── pack.toml          slack [[service]] (proxy_process)
├── adapter/           Slack ↔ gc HTTP/UDS bridge (Go module)
├── cli/               gc slack <verb> implementations (Go module)
├── commands/          gc slack <verb> wrappers (.sh + command.toml + help.md)
├── manifest/          Slack app manifest
├── schema/            JSON schemas for on-disk registries
├── scripts/           Python helpers (publish, react, status, ...)
├── tests/             pytest coverage for the python helpers
└── README / CHANGELOG / CONTRIBUTING
```

Verbs available after install:

```
# Implemented in cli/ (Go)
gc slack post-message --channel <C> --kind milestone ...
gc slack import-app --manifest manifest/app.json
gc slack sync-commands --workspace-id <T>
gc slack map-channel <C> --session <name>
gc slack map-rig <rig> --workspace-id <T> --channel <C>
gc slack enable-room-launch <C>

# Implemented in scripts/ (Python)
gc slack identity / publish / publish-to-channel / react /
       reply-current / bind-dm / bind-room / handle-alias /
       upload / status / retry-peer-fanout
```

## How to try it out

Two paths depending on whether you want to exercise the verbs against
a live Slack workspace or just build + test the pack standalone.

### Path A — build + test the pack standalone

```bash
git clone -b feat/import-slack \
    https://github.com/sjarmak/gascity-packs.git
cd gascity-packs/slack

( cd cli && go build -o gc-slack-cli . && go test -race ./... )
( cd adapter && go build -o gc-slack-adapter . && go test ./... )
python3 -m pytest tests/

./cli/gc-slack-cli --help        # 6 cobra verbs listed
./adapter/gc-slack-adapter --help
```

### Path B — wire into a gas-city for end-to-end Slack

**1. Add the pack to your city.**

```toml
# In <your-city>/city.toml
[imports.slack]
source = "/abs/path/to/your/clone/of/gascity-packs/slack"
```

**2. Build the adapter binary into the pack tree** (the slack `[[service]]`
expects `./adapter/gc-slack-adapter` relative to the pack root):

```bash
cd /abs/path/to/your/clone/of/gascity-packs/slack/adapter
go build -o gc-slack-adapter .
```

**3. Determine your GC API base URL.**

The adapter posts to gc on startup to register, and gc reverse-proxies
`/svc/slack/*` back to it over a UDS. The adapter needs the URL of
gc's HTTP API.

In **supervisor mode** (the default for cities started under
`gascity-supervisor.service` / `gc start`), the API is on **127.0.0.1:8372**.
You can verify:

```bash
curl -sS http://127.0.0.1:8372/v0/cities
# => {"items":[{"name":"<your-city>","running":true}],"total":1}
```

In **legacy controller mode** (no supervisor; `gc serve` directly on a
city), the API is on the port from your city's `[api] port` in `city.toml`
— typically `9443`. Check with:

```bash
grep -A2 '^\[api\]' <your-city>/city.toml
ss -ltnp | grep -E '8372|9443'
```

If both are listening, supervisor mode wins (8372).

**4. Provision the adapter env file.**

The adapter reads its config from a small env file that the supervisor
sources before spawning it. Drop a file at
`~/.config/gc-slack-adapter/env` with the values from step 3 plus your
Slack app credentials:

```bash
mkdir -p ~/.config/gc-slack-adapter
cat > ~/.config/gc-slack-adapter/env <<EOF
SLACK_BOT_TOKEN=xoxb-...
SLACK_SIGNING_SECRET=<from your Slack app's Basic Information page>
SLACK_WORKSPACE_ID=T0...
GC_API_BASE_URL=http://127.0.0.1:8372    # or :9443 if legacy mode
GC_CITY_NAME=<your-city-name>
LISTEN_PUBLIC=:8775                      # public port the adapter binds for Slack events
EOF
chmod 600 ~/.config/gc-slack-adapter/env
```

Then make the supervisor source it:

```bash
mkdir -p ~/.config/systemd/user/gascity-supervisor.service.d
cat > ~/.config/systemd/user/gascity-supervisor.service.d/slack-adapter-env.conf <<EOF
[Service]
EnvironmentFile=-/home/$USER/.config/gc-slack-adapter/env
EOF
systemctl --user daemon-reload
```

**5. Restart and confirm.**

```bash
systemctl --user restart gascity-supervisor
sleep 5
pgrep -af gc-slack-adapter           # one process running
gc slack post-message --help         # cobra help renders via the pack wrapper
```

If you'd rather run the adapter outside systemd (e.g. for dev), it's a
plain Go binary — `set -a; source ~/.config/gc-slack-adapter/env; set +a;
./adapter/gc-slack-adapter` works.

## Test plan

- [x] `cd slack/cli && go build ./...` clean
- [x] `cd slack/cli && go vet ./...` clean
- [x] `cd slack/cli && go test -race ./...` (8 packages, all PASS)
- [x] `cd slack/cli && go mod tidy` no-op (no diff)
- [x] `cd slack/adapter && go build ./...` clean
- [x] `cd slack/adapter && go vet ./...` clean
- [x] `cd slack/adapter && go test ./...` PASS (full -race suite)
- [x] `python3 -m pytest tests/ -x` (57 tests across 7 files PASS)
- [x] All six `commands/<cmd>.sh` wrappers smoke-pass against
      `gc-slack-cli --help` (post-message, import-app, sync-commands,
      map-channel, map-rig, enable-room-launch)
- [x] End-to-end against a live Slack workspace: `@mayor: ping` from a
      Slack channel routes to a bound mayor session, and a
      `gc slack publish-to-channel` reply lands threaded under the
      original message.
