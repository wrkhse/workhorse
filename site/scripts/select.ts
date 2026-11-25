import { Glob } from "bun";
import { groups, type Group, type Project } from "../../hub.config";

/**
 * Files no reader of the site needs, wherever a project keeps them: hidden
 * folders, dependencies, build output, test fixtures and agent instructions.
 */
export const NEVER = [
  ".*/**",
  "**/node_modules/**",
  "**/target/**",
  "**/fixtures/**",
  "mutants.out*/**",
  "**/AGENTS.md",
  "**/CLAUDE.md",
];

/** One page the hub pulls: its path in the project, and the group it shows under. */
export type Selected = { source: string; group: Group };

/** Natural order, so `slice-2` precedes `slice-10`. */
const natural = (a: string, b: string) =>
  a.localeCompare(b, undefined, { numeric: true });

/** The globs one group pulls: the overview is one page, every other group is optional. */
const patterns = (project: Project, group: Group): string[] =>
  group === "overview" ? [project.overview] : (project[group] ?? []);

/**
 * The pages a project shows, group by group in the hub's order. `files`
 * returns the repository paths one glob matches. A page goes to the first
 * group and glob that match it. A glob that matches nothing is reported in
 * `unmatched` rather than failing, since projects move pages while the hub
 * still names them.
 */
export function select(
  project: Project,
  files: (pattern: string) => string[],
): { pages: Selected[]; unmatched: string[] } {
  const skipped = [...(project.exclude ?? []), ...NEVER].map(
    (pattern) => new Glob(pattern),
  );
  const seen = new Set<string>();
  const pages: Selected[] = [];
  const unmatched: string[] = [];

  for (const { id: group } of groups) {
    for (const pattern of patterns(project, group)) {
      const found = files(pattern);
      if (found.length === 0) unmatched.push(pattern);

      for (const source of found.toSorted(natural)) {
        if (seen.has(source) || skipped.some((glob) => glob.match(source)))
          continue;
        seen.add(source);
        pages.push({ source, group });
      }
    }
  }

  return { pages, unmatched };
}

/** A capital S and a colon mark a status line, so prose and shell never pass for one. */
const STATUS = /^\s*(?:\*\*)?Status(?:\*\*)?\s*:/;
const HELD =
  /^\s*(?:\*\*)?Status(?:\*\*)?\s*:\s*(?:\*\*)?\s*(?:Planned|Held)\b/i;
const FENCE = /^\s*(?:```|~~~)/;

/**
 * Whether a page's status says Planned or Held. Planned design lives in
 * issues, so such a page is not shown. Only the lead counts, the lines before
 * the first `## ` section, so a later section's status never hides the page.
 * Lines inside fenced code are examples, never a status or a section.
 */
export function held(markdown: string): boolean {
  let fenced = false;

  for (const line of markdown.split("\n")) {
    if (FENCE.test(line)) {
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    if (line.startsWith("## ")) return false;
    if (STATUS.test(line)) return HELD.test(line);
  }

  return false;
}
