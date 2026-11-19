# `sandbox`

**Kind:** enforcer. **Status:** planned, in barn: `barn-exec` on macOS at B1 and on
Linux at B6. **Code:** `barn-exec` in
[wrkhse/barn](https://github.com/wrkhse/barn). **Plan:**
[barn#1](https://github.com/wrkhse/barn/issues/1).

Turns a grant into an operating-system policy and starts a process under it: a stall, an agent or an MCP server. File access, limits and the single allowed network destination are enforced here.

## Owns

- Translating a grant into a backend policy.
- Backends: nono on macOS, bubblewrap on Linux.
- Starting a stall, an agent or an MCP server, and stopping its whole process tree.

## Does not own

- Deciding what is allowed: that belongs to [`grant`](https://github.com/wrkhse/barn/blob/main/docs/grant.md).
- Network traffic beyond letting it reach the broker: that belongs to [`broker`](broker.md).

## Depends on

[`grant`](https://github.com/wrkhse/barn/blob/main/docs/grant.md). Native only; this is the one module that touches Seatbelt, Landlock or bubblewrap. It lives in barn, which depends on the contract by tag.

## Decisions

- **File access and limits are fixed when the agent starts** (2026-11-02). A change restarts the agent under the new grant and resumes its session.
- **The only network destination is the broker** (2026-11-02). tack's `control` calls go through it too, on a reserved path.
- **Agents and local MCP servers both run under it**, each with its own grant (2026-11-02).
- **Stop the whole process tree** (spike 8): killing the `nono run` supervisor alone leaves the agent running.
- **agentOS is not adopted** (spike 8). Revisit when it leaves beta and its Node layer runs current agents.

## Open questions

- Whether every agent resumes reliably after a restart: [planned spike](../spike/resume-and-events/PLAN.md).
- On Linux, Unix sockets stay reachable for a self-sandboxed process (spike 1). Use bubblewrap's mount namespace or nono's supervisor mode.
- `nono run` adds about 0.65 s to each start on the homelab (spike 8).

## Evidence

- In [`wrkhse/daemon-v0`](https://github.com/wrkhse/daemon-v0): `spike/sandbox/FINDINGS.md` (spike 1) and `spike/agentos/FINDINGS.md` (spike 8: escape probes, broker-only egress, costs against nono).
