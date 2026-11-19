import { github, hub, type Project } from "../../hub.config"

/** A project's latest published release; `date` is `YYYY-MM-DD`. */
export type Release = { tag: string; url: string; date: string; prerelease: boolean }

/** A project's plan (master) issue; `status` is already escaped for a table cell. */
export type Plan = {
  repo: string
  number: number
  title: string
  url: string
  status?: string
}

/**
 * One line of the roadmap. `link` is the project's section on the site, or its
 * repository when the hub has no pages for it.
 */
export type Row = { name: string; link: string; release?: Release; plan: Plan }

const API = "https://api.github.com"

const escape = (cell: string) => cell.replace(/\|/g, "\\|")

/**
 * The status a plan issue states on its own line, such as
 * `**Status: B0 accepted.** The owner…`, cut to its first sentence or the end
 * of its bold span so the table stays one short line per project.
 */
export function planStatus(body: string): string | undefined {
  const line = body
    .split(/\r?\n/)
    .find((candidate) => /^\s*(?:\*\*)?Status/.test(candidate))
  if (line === undefined) return undefined
  const text = line.replace(/^\s*(?:\*\*)?Status(?:\*\*)?\s*:\s*(?:\*\*)?\s*/i, "")
  const ends = [text.indexOf("**"), text.indexOf(". ")].filter((index) => index >= 0)
  const status = text
    .slice(0, ends.length === 0 ? undefined : Math.min(...ends))
    .trim()
    .replace(/\.$/, "")
  return status === "" ? undefined : escape(status)
}

function releaseCell(release: Release | undefined): string {
  if (release === undefined) return "None yet"
  const kind = release.prerelease ? ", prerelease" : ""
  return `[${release.tag}](${release.url})${kind}, ${release.date}`
}

function planCell(plan: Plan): string {
  const name = plan.repo.split("/").at(-1) ?? plan.repo
  const title = escape(plan.title.replace(/^Plan: /, ""))
  return `[${name}#${plan.number}](${plan.url}): ${title}`
}

/** The whole page. It has no file in this repository, so it offers no edit link. */
export function renderRoadmap(rows: Row[]): string {
  const lines = rows.map((row) => {
    const cells = [
      `[${row.name}](${row.link})`,
      releaseCell(row.release),
      planCell(row.plan),
      row.plan.status ?? "Not stated",
    ]
    return `| ${cells.join(" | ")} |`
  })
  return [
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
    ...lines,
    "",
  ].join("\n")
}

/**
 * One GitHub API read. A failed read throws rather than falling back, so a
 * build never publishes a stale roadmap. A token, when set, lifts the rate limit.
 */
async function get(path: string): Promise<unknown> {
  const headers = new Headers({
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
  })
  const token = process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN
  if (token) headers.set("Authorization", `Bearer ${token}`)
  const response = await fetch(`${API}${path}`, {
    headers,
    signal: AbortSignal.timeout(15_000),
  })
  if (!response.ok) throw new Error(`GitHub ${path}: ${response.status}`)
  return response.json()
}

const shape = (path: string, expected: string) =>
  new Error(`GitHub ${path}: expected ${expected}`)

function isDraft(entry: unknown, path: string): boolean {
  if (
    typeof entry === "object" &&
    entry !== null &&
    "draft" in entry &&
    typeof entry.draft === "boolean"
  )
    return entry.draft
  throw shape(path, "a release with a boolean draft")
}

/** A release with the instant it was published, kept to order releases by. */
type Published = { release: Release; at: string }

/** One listed release, or undefined for a draft or an entry not yet published. */
function published(entry: unknown, path: string): Published | undefined {
  if (isDraft(entry, path)) return undefined
  if (
    typeof entry === "object" &&
    entry !== null &&
    "tag_name" in entry &&
    typeof entry.tag_name === "string" &&
    "html_url" in entry &&
    typeof entry.html_url === "string" &&
    "published_at" in entry &&
    (entry.published_at === null || typeof entry.published_at === "string") &&
    "prerelease" in entry &&
    typeof entry.prerelease === "boolean"
  ) {
    const at = entry.published_at
    if (at === null) return undefined
    const release = {
      tag: entry.tag_name,
      url: entry.html_url,
      date: at.slice(0, 10),
      prerelease: entry.prerelease,
    }
    return { release, at }
  }
  throw shape(path, "a release with tag_name, html_url, published_at and prerelease")
}

/**
 * The most recently published release among GitHub's first few. GitHub does
 * not document the list's order, so the publish times decide; as ISO 8601
 * strings in UTC they order lexically.
 */
async function latestRelease(repo: string): Promise<Release | undefined> {
  const path = `/repos/${repo}/releases?per_page=10`
  const body = await get(path)
  if (!Array.isArray(body)) throw shape(path, "a list of releases")
  const entries: unknown[] = body
  const newest = entries
    .flatMap((entry) => published(entry, path) ?? [])
    .reduce<Published | undefined>(
      (latest, next) => (latest === undefined || next.at > latest.at ? next : latest),
      undefined,
    )
  return newest?.release
}

async function plan(repo: string, number: number): Promise<Plan> {
  const path = `/repos/${repo}/issues/${number}`
  const issue = await get(path)
  if (
    typeof issue === "object" &&
    issue !== null &&
    "title" in issue &&
    typeof issue.title === "string" &&
    "html_url" in issue &&
    typeof issue.html_url === "string"
  ) {
    const body = "body" in issue ? issue.body : undefined
    if (body === undefined || body === null || typeof body === "string") {
      const status = planStatus(body ?? "")
      const read = { repo, number, title: issue.title, url: issue.html_url }
      return status === undefined ? read : { ...read, status }
    }
  }
  throw shape(path, "an issue with title, html_url and a string or null body")
}

type Wanted = { name: string; link: string; repo: string; plan: number }

/** Every project with a plan, then every tracked repository, in config order. */
function wanted(): Wanted[] {
  const projects: readonly Project[] = hub.projects
  const pulled = projects.flatMap((project) =>
    project.plan === undefined
      ? []
      : [
          {
            name: project.name,
            link: `/${project.id}/`,
            repo: project.repo,
            plan: project.plan,
          },
        ],
  )
  const tracked = hub.tracked.map((entry) => ({
    name: entry.name,
    link: github(entry.repo),
    repo: entry.repo,
    plan: entry.plan,
  }))
  return [...pulled, ...tracked]
}

/** The generated `src/roadmap.md`, read from GitHub now. */
export async function roadmap(): Promise<string> {
  const rows = await Promise.all(
    wanted().map(async (want): Promise<Row> => {
      const [release, issue] = await Promise.all([
        latestRelease(want.repo),
        plan(want.repo, want.plan),
      ])
      const row = { name: want.name, link: want.link, plan: issue }
      return release === undefined ? row : { ...row, release }
    }),
  )
  return renderRoadmap(rows)
}
