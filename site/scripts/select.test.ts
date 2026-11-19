import { describe, expect, test } from "bun:test"
import { Glob } from "bun"
import type { Project } from "../../hub.config"
import { held, select } from "./select"

const list = [
  "README.md",
  "AGENTS.md",
  "docs/a.md",
  "docs/b.md",
  "docs/slice-10.md",
  "docs/slice-2.md",
  "crates/x/README.md",
  "crates/x/fixtures/README.md",
  "node_modules/p/README.md",
  ".github/ci/README.md",
]
const files = (pattern: string) => list.filter((path) => new Glob(pattern).match(path))

const project: Project = {
  id: "example",
  name: "example",
  repo: "wrkhse/example",
  branch: "main",
  summary: "An example project",
  overview: "README.md",
  guides: ["docs/b.md", "docs/*.md"],
  design: ["docs/*.md"],
  code: ["crates/**/README.md", "missing/*.md"],
  exclude: ["docs/a.md"],
}

describe("selecting a project's pages", () => {
  test("takes each page once, in group and natural order, leaving out excluded files", () => {
    expect(select(project, files)).toEqual({
      pages: [
        { source: "README.md", group: "overview" },
        { source: "docs/b.md", group: "guides" },
        { source: "docs/slice-2.md", group: "guides" },
        { source: "docs/slice-10.md", group: "guides" },
        { source: "crates/x/README.md", group: "code" },
      ],
      unmatched: ["missing/*.md"],
    })
  })
})

describe("a page's status", () => {
  test("planned or held in the lead hides the page", () => {
    expect(held("# Slice 4\n\n**Status:** Planned.\n")).toBe(true)
    expect(held("**Status: Planned.** Later.")).toBe(true)
    expect(held("Status: Held until barn B1.")).toBe(true)
    expect(held("**Status:** held")).toBe(true)
  })

  test("any other status, none, or one after the first section shows the page", () => {
    expect(held("**Status: Implemented.**")).toBe(false)
    expect(held("**Status:** In progress: rounds in core.")).toBe(false)
    expect(held("**Status: Approved, planned for B2.**")).toBe(false)
    expect(held("# A\n\nA page with no status.\n")).toBe(false)
    expect(held("# A\n\n## Later\n\n**Status:** Planned.\n")).toBe(false)
  })

  test("a status in fenced code or shell is not the page's", () => {
    expect(held("# Tool\n\n```sh\nstatus: held\n```\n")).toBe(false)
    expect(held("status=$?")).toBe(false)
  })
})
