# Workhorse

Coding agents make code cheap, but not trustworthy. They miss the larger
picture, do work no one sees, and reach whatever their machine can reach.
Workhorse is a family of small projects that make agents safe, steerable and
observable, each in its own repository with its own releases. This site
gathers their docs in one place, pulled from each repository when it builds.

<a href="/deck/" target="_self">The deck</a> tells the same story in slides.

## The idea

Every project follows [the Workhorse philosophy](/workhorse/PHILOSOPHY):

- **Hard boundaries.** Each project, crate and module owns one job and says
  what it does not own, so neither a person nor an agent can blur it.
- **Strict APIs.** Make the wrong decision hard to express: invalid states
  don't type-check, and a config that can't work is refused when it loads.
- **Nothing hidden.** Whatever an agent does, a person can see and change.
- **Proof.** A behavior is done when an executed check, one that would fail
  if it broke, shows it working through its real boundary.

## The system

One daemon, **barn**, runs every project's logic as a **stall**: a child process
with its own handlers, jobs and events, no network and no secrets of its own.
barn holds every listener a client connects to, adds the secrets, and is the
only way out to the network. The contracts a stall runs under live in Workhorse.

[The architecture](/workhorse/ARCHITECTURE) draws the whole system, with each
part's status and where its code lives.

## The projects

| Project | What it does | Language |
| --- | --- | --- |
| [barn](https://github.com/wrkhse/barn) | The only daemon: a supervisor, a stall per project, and the enforcers | Rust |
| [Workhorse](/workhorse/) | The contracts barn enforces: grant, steering, approvals, control | Rust |
| [atelier](/atelier/) | A personal software factory: a labelled issue becomes a proven, released pull request | Rust |
| [rungs](/rungs/) | A small step machine shared by atelier and Chauffeur: `no_std`, no allocation, no dependencies, proven with Kani | Rust |
| [sourcefed](/sourcefed/) | Tells agents and programs what changed in GitHub, Jira, Slack, feeds and schedules | TypeScript |
| [Chauffeur](/chauffeur/) | Judges what a coding agent is doing and steers it: sense, classify, act | Rust, TypeScript adapters |
| [tack](/tack/) | Write a coding-agent plugin once and run it in OpenCode, Pi, Claude Code and Codex | TypeScript |

[o11y](https://github.com/wrkhse/o11y), one trace across every module, is
proposed and paused.

[How they connect](/connections) lists what crosses between them, and
[the roadmap](/roadmap) shows where each one is.

## Why one hub

Each project's repository is its own source of truth: its plan, its docs and
its history stay there. The hub is where they meet. Every page under a
project's name is pulled from that project's repository at the branch
[`hub.config.ts`](https://github.com/wrkhse/workhorse/blob/main/hub.config.ts)
names, and every repository the hub mentions is named in that one file.

## History

Earlier versions of Workhorse are archived as evidence, not design:

- [`wrkhse/daemon-v0`](https://github.com/wrkhse/daemon-v0): the capability
  daemon and its spikes, as of 2026-10-30.
- [`wrkhse/fleet-v0`](https://github.com/wrkhse/fleet-v0): the autonomous
  coding fleet on Cloudflare, as of 2026-09-15.
- [`wrkhse/workhorse-legacy`](https://github.com/wrkhse/workhorse-legacy):
  the original command-line and terminal UI tool, as of 2026-07-14.
