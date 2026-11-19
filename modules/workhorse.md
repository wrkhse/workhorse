# `workhorse`

**Kind:** composition root. **Status:** planned, in barn's B9. **Code:** the
workhorse stall and the CLI in this repository. **Plan:**
[barn#1](https://github.com/wrkhse/barn/issues/1).

The command-line tool and the workhorse stall: one stall on barn, holding sessions,
the approvals queue, steering and `control`. It is the only place concrete
implementations are chosen and wired together.

```sh
workhorse run --profile repo-work -- opencode   # start an agent under a profile
workhorse status                                # every session's grant and recent denials
barn stalls start workhorse                   # a request on its socket starts it too
```

## Owns

- The CLI.
- The workhorse stall, which holds sessions, the [`steering`](https://github.com/wrkhse/barn/blob/main/docs/steering.md) evaluation
  and the [`approvals`](https://github.com/wrkhse/barn/blob/main/docs/approvals.md) queue, and serves [`control`](https://github.com/wrkhse/barn/blob/main/docs/control.md). barn
  supplies the enforcers.
- Loading profiles, storing sessions, approvals and logs.
- Asking barn to start each agent as a guarded process under the session's grant,
  through `proc.spawn`.

## Does not own

Any rule. Every decision about access, verdicts or approvals belongs to a contract module.

## Depends on

Every layer 1 module, and barn, which starts it and supplies the enforcers.

## Decisions

- **One daemon on the machine: barn.** The workhorse stall holds sessions, approvals
  and steering; barn holds the broker, the gateway and every listener (2026-11-17).
- **Each session prints a one-screen summary of its grant** when it starts (2026-11-02).
- **The stall starts on demand** (2026-11-17). The next request on its socket starts
  it, and it exits when no session remains. Nothing idles.
- **barn starts local MCP servers** in their own sandboxes under their own grants, as
  it starts agents (2026-11-02).

## Open questions

- Reaching the stall from a phone when it is not running: this belongs to layer 2's
  link.
