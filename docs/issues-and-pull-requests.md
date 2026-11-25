# Issues and pull requests

An issue holds the idea: what a person can do and how we know it works.
Code detail goes in the pull request. Both are short enough to read in one
sitting.

## A slice issue

About 40 to 60 lines, in this order:

1. **Status line.** Planned, In progress or Implemented (vX), and what it
   depends on.
2. **What a person can do.** Two or three sentences in plain words, with one
   example, then one Mermaid diagram of three to six nodes in one direction.
3. **The parts.** Four to six bullets, one or two sentences each: what the
   part does and why. No file paths, flags, field names, version pins,
   timeouts or code.
4. **How each is verified.** One line per behavior a person would notice.
5. **End-to-end check in CI.** Two or three sentences: the real harness, what
   triggers the feature, and what must be seen.
6. **Decided.** A table of settled choices, one line each, with who decided
   and when.

An issue has no open questions. The worker settles them with the supervisor
before the issue is posted, and the answers go in Decided. A failure table
appears only when failure behavior is the feature, with at most six rows.
Rejected alternatives get at most one line in Decided.

## A pull request

At most about 25 lines, in this order:

1. **Recording**, when the pull request ships one: the GIF first, then one
   sentence on what it shows.
2. **Part of #N**, and one line on what the pull request adds.
3. **Changes.** Three to five bullets, each one thing a reviewer can check.
4. **Proof.** The checks that ran, with run IDs; for a flaky-check fix, the
   loop runs before and after.

## Recordings

A recording shows the released candidate working, at a pace a person can
follow. Each step holds on screen for two to three seconds before the next
starts, with a caption naming it: the action, the result, then the log line
that confirms it. The final state holds for at least three seconds.

## Prose

Present tense, lines of at most 85 columns, and no history words. Write what
is true or planned, not how the text got there.
