# Harness notes

**Status:** planned. No harness is built, and nothing here is decided beyond the
shape of the work. Until there is one, existing agents (OpenCode, Pi, Claude Code
and Codex) fill layer 3, and [tack](modules/tack.md) is how they reach layer 1.

Workhorse is simple and runs on open standards, much like [fx.sh](https://fx.sh).
Workhorse is the light base everything else is built on, and it is entirely
pluggable.

## Harnesses

- **Equestrian**: human driven. Two agents, one for the person to use and a
  supervisor agent for housekeeping such as memory, paper-cut measurements,
  approvals and steering.
- **Stable**: completely automated, with no human involvement. The supervisor and
  coordinator agents are built in.
- **Mule**: everyday use. One-off questions and knowledge retrieval, much like a
  chatbot.
- **Polo**: a single agent that can do everything, over the phone, chat or email,
  and avoids chat interfaces for generative UIs.

## What a harness owes

MCPs, skills, tool calling, compaction, prompt caching and subagents each look
different from here than in the current standards, and sandboxing, extensibility,
tasks and steering are extra capabilities a harness gets from layer 1.

### MCPs

The current spec adds three capabilities to an application: prompts, resources
and tools.

Every MCP attaches to a single server that provides the access the service asks
for, which gives natural sandboxing. We use the extension capabilities of MCP to
add `json-render` for generic generative UIs, so the same experience works across
platforms: web, TUI and more.

MCPs:

- filesystem (tgrep)
- web
- subagents
- rlm

It can be instantiated like this:

```ts
const agent = createAgent({
  mcps: [
    mcp((ctx) => ({
      tools: [ctx.tools.read, ctx.tools.write],
    })),
  ],
});
```

This way we define what capabilities are available to the agent per MCP, and need
no custom tools.

### Skills

A skill fits into an MCP as a resource with the URI `skill://`.

### Tool calling

Code mode, which sandboxes naturally.

### Compaction

Learn from Codex. There are several compaction strategies; Magic Context is a good
one.

### Prompt caching

Learn from Codex and Pi.

### Subagents

RLM.

### Extensibility

Everything is extendable and hot-reloadable.

### Sandboxing

First-class, from layer 1: barn, the one daemon, starts every agent under its
session's grant. A harness asks for a process; it never builds its own sandbox.

### Tasks

Background operations that can be run, paused and removed easily, as an MCP
extension.

### Steering

Deterministic rules that fire when something in the context runs, as an MCP
extension. The rules and their verdicts are layer 1's
[`steering`](modules/steering.md); a harness applies them.
