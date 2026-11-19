# Roadmap

Each project ships one vertical slice at a time, and its owner reviews each
before the next starts. Each project's plan is the source of truth; this page
says where each one is. [barn's plan](https://github.com/wrkhse/barn/issues/1)
gives the order the work comes in.

```mermaid
flowchart TB
    B0["barn B0<br/>in place"] --> B1["barn B1<br/>protocol and supervisor<br/>in progress"]
    B1 --> B2["barn B2 to B4<br/>broker, MCP, budgets"]
    B2 --> B56["barn B5 and B6<br/>upgrade, Linux"]
    B56 --> B7["barn B7<br/>JSON-RPC listeners"]
    B1 --> SF["sourcefed's stall<br/>S0 to S8"]
    B2 --> SF
    B56 --> SF
    B7 --> B8["barn B8<br/>the Chauffeur stall"]
    CH["Chauffeur's slice 13<br/>1.0.0"] --> B8
    SF --> B9["barn B9<br/>the workhorse stall"]
    B8 --> B9
    B9 --> B10["barn B10<br/>the atelier stall"]
```

| Project | Now | Next | Plan |
| --- | --- | --- | --- |
| barn | B0 in place: the repository, its gates and the protocol's fixed parts | B1, in progress in [barn#7](https://github.com/wrkhse/barn/pull/7): the connect-back transport, the envelope and the stall SDK | [barn#1](https://github.com/wrkhse/barn/issues/1) |
| Workhorse | The contracts designed; barn builds the enforcers | Milestones 1 and 2, with barn's B9 | [barn#13](https://github.com/wrkhse/barn/issues/13) |
| sourcefed | `0.5.2`: issue collections, Jira queries, schedules and program targets, with `daemon.health` | S0, the golden harness, then S1 to S5: its stall is Rust, with the TypeScript providers as plugins | [sourcefed#31](https://github.com/wrkhse/sourcefed/issues/31), [barn#3](https://github.com/wrkhse/barn/pull/3) |
| Chauffeur | v2 slices 0 to 2 implemented, released as `chauffeur-next` `1.0.0-rc.5`; slice 3 in progress | Slices 4 to 13, then its stall in B8 | [slices](/chauffeur/docs/plans/slices/) |
| atelier | Slices 0 to 2 implemented in [#1](https://github.com/wrkhse/atelier/issues/1) (`0.1.0-rc.8`); slice 3 in [#43](https://github.com/wrkhse/atelier/issues/43) | Slice 4, the sourcefed trigger; its stall last, in B10 | [slices](/atelier/docs/plans/) |
| tack | T1 and T2 implemented; T3 in progress | T4 to T8 | [tack#1](https://github.com/wrkhse/tack/issues/1) |
| rungs | Released, `v0.1.0`: plans and runs, proven with Kani | Adopted by atelier's pipelines and Chauffeur's strategies | [rungs#1](https://github.com/wrkhse/rungs/issues/1) |
| o11y | Approved and active | O0, the SDK | [o11y#1](https://github.com/wrkhse/o11y/issues/1) |
