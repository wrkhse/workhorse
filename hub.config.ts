/**
 * Every repository the hub names: the projects whose docs it pulls, the
 * repositories the roadmap tracks before they have pages, and the archived
 * ones it lists as history. Nothing else holds an owner or a branch.
 */
const owner = "wrkhse";

/** The groups a project's section is split into, in the sidebar's order. */
export const groups = [
  { id: "overview", title: "Overview" },
  { id: "guides", title: "Guides" },
  { id: "reference", title: "Reference" },
  { id: "design", title: "Design" },
  { id: "code", title: "Code" },
] as const;

export type Group = (typeof groups)[number]["id"];

/** A repository the roadmap follows by its plan issue; it has no pages. */
export type Tracked = {
  name: string;
  /** `owner/name` on GitHub. */
  repo: string;
  /** The repository's master issue. */
  plan: number;
};

export type Project = {
  /** The project's path on the site, such as `/atelier/`. */
  id: string;
  name: string;
  /** `owner/name` on GitHub. */
  repo: string;
  /** The branch the hub pulls, and that its links to code point at. */
  branch: string;
  summary: string;
  /** The page the section opens on, from the repository's root. */
  overview: string;
  /**
   * Globs from the repository's root. A page sits in the first group, in
   * `groups` order, that matches it.
   */
  guides?: string[];
  /** Globs, as for `guides`. */
  reference?: string[];
  /** Globs, as for `guides`. */
  design?: string[];
  /** Globs, as for `guides`. */
  code?: string[];
  /** Globs the groups match that the hub leaves out: pages the docs scan retires. */
  exclude?: string[];
  /** The branch the deck's recordings come from, when it is not `branch`. */
  demos?: string;
  /** The project's master issue, shown on the roadmap. */
  plan?: number;
};

export type Archived = {
  repo: string;
  summary: string;
};

export const hub = {
  /** This repository: it builds the hub and is pulled from its own checkout. */
  repo: `${owner}/workhorse`,
  site: "https://workhorse-docs.stevenjpx2.workers.dev",
  /**
   * Owners the projects were transferred from. A GitHub link in a project's
   * docs that still names one reaches the same project.
   */
  formerOwners: ["StevenJPx2"],
  projects: [
    {
      id: "workhorse",
      name: "Workhorse",
      repo: `${owner}/workhorse`,
      branch: "main",
      summary: "The family's docs hub, philosophy and repository standards",
      overview: "README.md",
      guides: ["docs/*.md"],
      design: ["PHILOSOPHY.md", "RANT.md"],
    },
    {
      id: "barn",
      name: "barn",
      repo: `${owner}/barn`,
      branch: "main",
      summary:
        "The shared daemon: a supervisor that runs each project's stall in its own process",
      overview: "README.md",
      reference: ["docs/*.md"],
      plan: 1,
    },
    {
      id: "atelier",
      name: "atelier",
      repo: `${owner}/atelier`,
      branch: "main",
      summary:
        "A CI engine for monorepos: gate presets on moon, one GitHub check per gate",
      overview: "README.md",
      design: ["docs/plans/README.md"],
      plan: 1,
    },
    {
      id: "rungs",
      name: "rungs",
      repo: `${owner}/rungs`,
      branch: "main",
      summary:
        "A small, proven step machine: no_std, no alloc, no dependencies",
      overview: "README.md",
      plan: 1,
    },
    {
      id: "sourcefed",
      name: "sourcefed",
      repo: `${owner}/sourcefed`,
      branch: "main",
      summary:
        "Tells agents and programs what changed in GitHub, Jira, Slack, feeds and schedules",
      overview: "README.md",
      guides: ["docs/program-targets.md", "docs/subscription-lifecycle.md"],
      reference: ["packages/sdk/README.md", "packages/sourcefed/README.md"],
      design: ["docs/source-plugins/*.md"],
      code: ["packages/daemon/src/**/README.md", "providers/**/README.md"],
      plan: 3,
    },
    {
      id: "chauffeur",
      name: "Chauffeur",
      repo: `${owner}/chauffeur`,
      branch: "v2",
      summary:
        "Enhances a coding agent's context as it works: sense, classify, act",
      overview: "README.md",
      guides: [
        "playground/README.md",
        "docs/integrations/README.md",
        "docs/integrations/sourcefed.md",
        "docs/migration/README.md",
        "docs/migration/audit.md",
        "docs/migration/judges.md",
        "docs/migration/redaction.md",
        "docs/migration/rule-format.md",
        "docs/migration/sourcefed.md",
      ],
      reference: [
        "docs/cli/README.md",
        "docs/cli/audit.md",
        "docs/cli/daemon.md",
        "docs/cli/emit.md",
        "docs/cli/navigate.md",
        "packages/chauffeur/README.md",
      ],
      design: ["docs/plans/slices/*.md"],
      code: ["crates/**/README.md", "adapters/*/README.md"],
      exclude: [
        "docs/plans/slices/slice-0.md",
        "crates/judges/src/tiers/*/README.md",
      ],
      // Present v1's feature recordings while the documentation stays on v2.
      demos: "main",
      plan: 43,
    },
    {
      id: "tack",
      name: "tack",
      repo: `${owner}/tack`,
      branch: "main",
      summary: "Write a coding-agent plugin once and run it in every agent",
      overview: "README.md",
      design: ["docs/plans/**/*.md"],
      code: ["src/**/README.md"],
      plan: 1,
    },
    {
      id: "equestrian",
      name: "equestrian",
      repo: `${owner}/equestrian`,
      branch: "main",
      summary:
        "A coding harness you drive: your agent, plus a supervisor that keeps memory, approvals and steering in order",
      overview: "README.md",
      plan: 1,
    },
    {
      id: "stable",
      name: "stable",
      repo: `${owner}/stable`,
      branch: "main",
      summary:
        "A fully automated coding harness: supervisor and coordinator agents run the work with no one at the keyboard",
      overview: "README.md",
      plan: 1,
    },
    {
      id: "mule",
      name: "mule",
      repo: `${owner}/mule`,
      branch: "main",
      summary:
        "An everyday assistant: one-off questions and knowledge retrieval, like a chatbot that can use your tools",
      overview: "README.md",
      plan: 1,
    },
    {
      id: "polo",
      name: "polo",
      repo: `${owner}/polo`,
      branch: "main",
      summary:
        "One agent that does everything, reached by phone, chat or email, with generated UI instead of a chat window",
      overview: "README.md",
      plan: 1,
    },
  ] satisfies Project[],
  /**
   * Repositories the roadmap follows by their plan issue, with no pages on the
   * site yet.
   */
  tracked: [] satisfies Tracked[],
  history: [
    {
      repo: `${owner}/daemon-v0`,
      summary: "The capability daemon and its spikes, as of 2026-10-30",
    },
    {
      repo: `${owner}/fleet-v0`,
      summary: "The autonomous coding fleet on Cloudflare, as of 2026-09-15",
    },
    {
      repo: `${owner}/workhorse-legacy`,
      summary:
        "The original command-line and terminal UI tool, as of 2026-07-14",
    },
  ] satisfies Archived[],
};

export const github = (repo: string) => `https://github.com/${repo}`;
