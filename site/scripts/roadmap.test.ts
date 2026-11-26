import { describe, expect, test } from "bun:test";
import { planStatus, renderRoadmap, type Row } from "./roadmap";

describe("a plan issue's status", () => {
  test("ends with its bold span", () => {
    const body =
      "**Status: B0 accepted; B1 in progress in [barn#7](https://github.com/wrkhse/barn/pull/7).** The owner made...";

    expect(planStatus(body)).toBe(
      "B0 accepted; B1 in progress in [barn#7](https://github.com/wrkhse/barn/pull/7)",
    );
  });

  test("after a bold label ends with its first sentence", () => {
    const body =
      "**Status:** Approved, resumed 2026-11-19 at the owner's word. O0 may be framed; ...";

    expect(planStatus(body)).toBe(
      "Approved, resumed 2026-11-19 at the owner's word",
    );
  });

  test("leaves out the words after its bold span", () => {
    const body =
      "**Status: Approved plan, being built** on the `v2` branch. This is...";

    expect(planStatus(body)).toBe("Approved plan, being built");
  });

  test("keeps the periods inside a link", () => {
    const body =
      "**Status: Implemented in [`v0.1.0`](https://github.com/StevenJPx2/rungs/releases/tag/v0.1.0)** ([#3](https://github.com/StevenJPx2/rungs/pull/3))";

    expect(planStatus(body)).toBe(
      "Implemented in [`v0.1.0`](https://github.com/StevenJPx2/rungs/releases/tag/v0.1.0)",
    );
  });

  test("of one word drops the note after it", () => {
    const body = "**Status: Proposed** (owner, 2026-11-19). Master issue: ...";

    expect(planStatus(body)).toBe("Proposed");
  });

  test("is found on a line after a heading", () => {
    const body = "# Plan: barn\n**Status: Proposed** (owner, 2026-11-19).";

    expect(planStatus(body)).toBe("Proposed");
  });

  test("is undefined when no line states one", () => {
    const body = "# Plan: barn\n\nThe shared daemon, built in slices.";

    expect(planStatus(body)).toBe(undefined);
  });

  test("escapes a pipe for the table", () => {
    expect(planStatus("Status: Ready | blocked")).toBe("Ready \\| blocked");
  });
});

describe("the roadmap page", () => {
  test("has one row per project, with its release, plan and status", () => {
    const rows: Row[] = [
      {
        name: "Chauffeur",
        link: "/chauffeur/",
        release: {
          tag: "v1.0.0-rc.5",
          url: "https://github.com/wrkhse/chauffeur/releases/tag/v1.0.0-rc.5",
          date: "2026-11-18",
          prerelease: true,
        },
        plan: {
          repo: "wrkhse/chauffeur",
          number: 4,
          title: "Plan: Chauffeur v2 | slices",
          url: "https://github.com/wrkhse/chauffeur/issues/4",
          status: "Slice 3 in progress",
        },
      },
      {
        name: "barn",
        link: "https://github.com/wrkhse/barn",
        plan: {
          repo: "wrkhse/barn",
          number: 1,
          title: "Plan: barn, the sandbox and runtime-stall engine",
          url: "https://github.com/wrkhse/barn/issues/1",
        },
      },
    ];

    expect(renderRoadmap(rows)).toBe(
      [
        "---",
        "editLink: false",
        "---",
        "",
        "# Roadmap",
        "",
        "Each project's latest release and its plan, read from GitHub when the site",
        "builds. A plan issue holds the project's slices, their order and their status.",
        "",
        "| Project | Latest release | Plan | Status |",
        "| --- | --- | --- | --- |",
        "| [Chauffeur](/chauffeur/) | [v1.0.0-rc.5](https://github.com/wrkhse/chauffeur/releases/tag/v1.0.0-rc.5), prerelease, 2026-11-18 | [chauffeur#4](https://github.com/wrkhse/chauffeur/issues/4): Chauffeur v2 \\| slices | Slice 3 in progress |",
        "| [barn](https://github.com/wrkhse/barn) | None yet | [barn#1](https://github.com/wrkhse/barn/issues/1): barn, the sandbox and runtime-stall engine | Not stated |",
        "",
      ].join("\n"),
    );
  });
});
