# gc gastown kill-triage

May this PID be killed by an automated patrol step? Read-only: it measures,
prints, and exits. It never signals anything — the caller owns the kill, this
owns the refusal.

```
  gc gastown kill-triage --pid 61677                    # triage one pid
  gc gastown kill-triage --pid 100 --pid 200            # several
  gc gastown kill-triage --require-zombie --pid 61677   # also require stat=Z
```

## Why it exists

Two deacon patrol steps converted a heuristic signal directly into an
irreversible action with nothing in between, and both fired on a HEALTHY town
(gp-aik):

- `orphan-process-cleanup` matched orphans with `ps aux | grep -E 'claude|node'
  | grep '?'`. On the reporting host that matched 95 processes — five separate
  cities' tmux servers, desktop app helpers, live MCP servers, and every agent
  in this town. Zero were orphans. It also matched **this town's own tmux
  server**, which `ps aux` reveals because the server's argv contains the
  `exec claude ...` it launched; that process sits at ppid=1 with TTY `?`, so it
  satisfies both stated orphan heuristics. Killing it takes down every agent in
  the town, including the deacon running the step.

- `dolt-health` reported `zombie_count=1` and the step said to kill the pid.
  That pid was `stat=Ss` — not a Unix zombie — six minutes old, 669MB resident,
  with a live agent for a parent. `zombie_count` does not mean Z.

gp-9ur required pane corroboration before a WARRANT for exactly this reason.
This is the same rule on the KILL paths, which gp-9ur does not cover.

## What it checks

Three questions, all of which must pass. Any one failing is a refusal.

1. **Is it ours?** Ancestry to this town's session host, else the working
   directory (macOS cannot expose another process's environment). A process
   this town cannot claim is never this town's to kill.
2. **Is it abandoned?** `ppid=1` is a hypothesis, not proof — the town's own
   session host sits at ppid=1 permanently. Under `--require-zombie`, "zombie"
   must mean `stat=Z`, not a reporter's field name.
3. **Is anything using it?** A process with live children is hosting them.

## Output

One TSV row per pid on stdout, column header on stderr:

```
verdict <TAB> pid <TAB> stat <TAB> ppid <TAB> owner <TAB> reason
```

| verdict | meaning |
|---------|---------|
| `kill-candidate` | every refusal test passed — the caller may propose a kill |
| `refuse-not-ours` | ancestry/cwd place it elsewhere, or nowhere we can claim |
| `refuse-live-agent` | descends from this town's session host — a live agent |
| `refuse-session-host` | it IS a session host, or has live children |
| `refuse-not-zombie` | `--require-zombie` set and stat is not Z |
| `refuse-unverifiable` | process state unreadable — never a licence to kill |

## Exit codes

| code | meaning |
|------|---------|
| 0 | no kill candidates — everything refused, or nothing asked about |
| 1 | at least one kill-candidate on stdout |
| 2 | could not run — **nothing was triaged, which is not a clearance** |

The 0/1 polarity is deliberate and is the opposite of a "did it pass" check. The
value you get from an empty run, a refusal, or an unhandled edge is
0/no-candidates, so a caller that ignores the output entirely still kills
nothing.
