# Workhorse

Workhorse is an open protocol for durable, sandboxed agent infrastructure: the
contracts one daemon enforces for every project on your machine.

Status: being built. [ARCHITECTURE.md](ARCHITECTURE.md) shows the system as it
will be, with each part's status, and [the barn plan](https://github.com/wrkhse/barn/issues/1)
builds it. [OVERVIEW.md](OVERVIEW.md) says what the protocols are, and
[PHILOSOPHY.md](PHILOSOPHY.md) holds the design principles.

Projects live under the [`wrkhse`](https://github.com/wrkhse) GitHub organization.

| Project | What it is |
| --- | --- |
| [`wrkhse/barn`](https://github.com/wrkhse/barn) | The only daemon: a supervisor, a stall per project, and the enforcers |
| [`wrkhse/sourcefed`](https://github.com/wrkhse/sourcefed) | What changed in GitHub, Jira, Slack, feeds and schedules, delivered to an agent |
| [`wrkhse/chauffeur`](https://github.com/wrkhse/chauffeur) | Judges what an agent is doing, and steers it |
| [`wrkhse/atelier`](https://github.com/wrkhse/atelier) | A labelled issue becomes a proven pull request |
| [`wrkhse/rungs`](https://github.com/wrkhse/rungs) | The step machine inside atelier's pipelines and Chauffeur's strategies |
| [`wrkhse/tack`](https://github.com/wrkhse/tack) | Write a coding-agent plugin once and run it in every agent |
| [`wrkhse/o11y`](https://github.com/wrkhse/o11y) | One trace across every module; proposed and paused |

Archived, kept as evidence:

- [`wrkhse/daemon-v0`](https://github.com/wrkhse/daemon-v0): the capability daemon, every
  spike it ran and the uniform-stack proposal, as of 2026-10-30.
- [`wrkhse/workhorse-legacy`](https://github.com/wrkhse/workhorse-legacy): the command-line
  and terminal UI tool, as of 2026-07-14.
- [`wrkhse/fleet-v0`](https://github.com/wrkhse/fleet-v0): the autonomous coding fleet on
  Cloudflare, as of 2026-09-15.

## Site

[`site/`](site/README.md) builds the hub: these docs and every related project's,
pulled from their own repositories, with a deck at `/deck`. [`hub.config.ts`](hub.config.ts)
names every repository.
