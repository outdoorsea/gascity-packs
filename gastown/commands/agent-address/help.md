Resolve a sibling agent's address in this rig, or refuse to answer.

Gas Town addresses an agent as `<rig>/<binding-prefix><role>`, where the
binding prefix comes from the import binding in city.toml — `[rigs.imports.gastown]`
makes the prefix `gastown.`, so the refinery is `myrig/gastown.refinery`.
Formulas compose that address by template substitution:

    "${GC_RIG:+$GC_RIG/}{{binding_prefix}}refinery"

When `{{binding_prefix}}` renders empty, the result degrades to `myrig/refinery`
— an address no agent answers to. Nothing rejects it: `gc bd update --assignee`
accepts any string, and there is no referential integrity between a bead's
assignee and the agent roster. The bead then reads healthy in every listing
while generating zero demand, and it strands silently (gp-0fz).

This command exists so a caller can stop composing addresses by string
concatenation and ask for one instead.

Usage:
  gc gastown agent-address <role>
  gc gastown agent-address <role> --candidate <addr>
  gc gastown agent-address <role> --quiet

  <role>        sibling role to address: refinery, witness, polecat, ...
  --candidate   the address the caller composed. Optional, and worth supplying:
                it is what lets this command DETECT a failed substitution and
                say so, rather than silently routing around it.
  --quiet       suppress advisory stderr; refusals still print.

Two independent signals decide the answer:

  SELF     this session's own address (GC_AGENT, else GC_TEMPLATE) is split into
           rig + binding prefix and recomposed with the requested role. A session
           running as `myrig/gastown.furiosa` is bound under `gastown.` by
           construction, so self already carries whatever `{{binding_prefix}}`
           was supposed to render. Needs no substitution, no daemon, no network.
  ROSTER   `gc agent list --json` .agents[].qualified_name — the addresses
           city.toml actually defines. Config-derived, so it covers agents that
           have never started a session. This is the validation the bead write
           itself does not perform.

SELF is tried before the candidate, deliberately: the candidate is the value
under suspicion, while SELF derives from an identity the runtime had to get
right for the session to exist at all. If the roster contradicts SELF, the
roster wins — it is the definition.

An unreadable roster is NOT treated as an empty one. A daemon blip must not
condemn a correct address, so it downgrades the result to "unverified" and says
so on stderr, rather than refusing.

A candidate that loses is always reported. The repair is a symptom fix; the
cause is a substitution that rendered wrong, and it stays broken at every other
call site until someone sees that line.

Exit codes:
  0  resolved — stdout holds one address, safe to write
  1  REFUSED — no trustworthy address exists; do NOT write an assignee
  2  could not run (bad arguments) — nothing was evaluated, also a refusal

Treat every non-zero exit identically: do not write an assignee. Halting a
handoff is recoverable and loud. Writing an address no agent answers to is
neither.
