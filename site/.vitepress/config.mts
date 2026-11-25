import { existsSync, readFileSync } from "node:fs";
import { join, posix } from "node:path";
import { defineConfig, type DefaultTheme } from "vitepress";
import { github, groups, hub, type Project } from "../../hub.config";
import { address, linker } from "./links";
import { MANIFEST, SITE, SRC, type Pulled } from "./sources";

if (!existsSync(MANIFEST))
  throw new Error("No pulled pages: run `bun run pull` first.");
const pulled: Pulled[] = JSON.parse(readFileSync(MANIFEST, "utf8"));
const links = linker(pulled);
const HUB_BRANCH =
  hub.projects.find((project) => project.repo === hub.repo)?.branch ?? "main";

function title(page: string): string {
  const heading = readFileSync(join(SRC, page), "utf8").match(/^# (.+)$/m)?.[1];
  return heading?.replaceAll("`", "") ?? posix.basename(page, ".md");
}

/** Two pages of one group with one title, such as several crates' READMEs, say where they are. */
function items(members: Pulled[]): DefaultTheme.SidebarItem[] {
  const labelled = members.map((entry) => ({
    entry,
    label: title(entry.page),
  }));
  return labelled.map(({ entry, label }) => {
    const shared = labelled.filter((other) => other.label === label).length > 1;
    return {
      text: shared ? `${label} · ${posix.dirname(entry.source)}` : label,
      link: address(entry.page),
    };
  });
}

/**
 * Every project's section shows the same groups in the same order, chosen in
 * `hub.config.ts`. Code comes last and starts collapsed; an empty group is left out.
 */
function projectSidebar(project: Project): DefaultTheme.SidebarItem[] {
  const pages = pulled.filter((entry) => entry.project === project.id);
  return groups.flatMap(({ id, title: text }) => {
    const members = pages.filter((entry) => entry.group === id);
    if (members.length === 0) return [];
    return [
      {
        text,
        items: items(members),
        ...(id === "code" && { collapsed: true }),
      },
    ];
  });
}

const deck = { text: "Deck", link: "/deck/", target: "_self" };

const hubSidebar: DefaultTheme.SidebarItem[] = [
  {
    text: "The hub",
    items: [
      { text: "Home", link: "/" },
      { text: "Philosophy", link: "/workhorse/PHILOSOPHY" },
      { text: "Rant", link: "/workhorse/RANT" },
      { text: "How it fits", link: "/how-it-fits" },
      { text: "Roadmap", link: "/roadmap" },
      {
        text: "Contributing",
        items: [
          {
            text: "Repository standards",
            link: "/workhorse/docs/repository-standards",
          },
        ],
      },
      deck,
    ],
  },
  {
    text: "Projects",
    items: hub.projects.map((project) => ({
      text: project.name,
      link: `/${project.id}/`,
    })),
  },
  {
    text: "History",
    items: hub.history.map((archived) => ({
      text: archived.repo,
      link: github(archived.repo),
    })),
  },
];

export default defineConfig({
  title: "Workhorse",
  description:
    "A family of projects for safe, steerable, observable coding agents",
  srcDir: SRC,
  cleanUrls: true,
  // The deck is built beside the site, so the build cannot see its pages.
  ignoreDeadLinks: [/^\/deck\//],
  vite: {
    resolve: {
      alias: [
        { find: /^vue(?=$|\/)/, replacement: join(SITE, "node_modules/vue") },
      ],
    },
    // Mermaid 12 bundles ELK as one 1.6 MB chunk. It loads only for a diagram
    // laid out with ELK, and the theme lays every diagram out with dagre.
    build: { chunkSizeWarningLimit: 1600 },
  },
  themeConfig: {
    nav: [
      { text: "How it fits", link: "/how-it-fits" },
      { text: "Roadmap", link: "/roadmap" },
      {
        text: "Projects",
        items: hub.projects.map((project) => ({
          text: project.name,
          link: `/${project.id}/`,
        })),
      },
      deck,
    ],
    sidebar: {
      ...Object.fromEntries(
        hub.projects.map((project) => [
          `/${project.id}/`,
          projectSidebar(project),
        ]),
      ),
      "/": hubSidebar,
    },
    outline: [2, 3],
    search: { provider: "local" },
    socialLinks: [{ icon: "github", link: github(hub.repo) }],
    // The pattern runs in the browser, so it reads what transformPageData wrote.
    editLink: { pattern: ({ frontmatter }) => String(frontmatter.edit) },
  },
  transformPageData(page) {
    const project = links.project(page.relativePath);
    const source = links.source(page.relativePath);
    page.frontmatter.edit =
      project && source
        ? `${github(project.repo)}/edit/${project.branch}/${source.source}`
        : `${github(hub.repo)}/edit/${HUB_BRANCH}/site/src/${page.relativePath}`;
  },
  markdown: {
    config(md) {
      const fence = md.renderer.rules.fence;
      md.renderer.rules.fence = (tokens, at, options, env, self) => {
        const token = tokens[at];
        if (token?.info.trim() !== "mermaid")
          return fence?.(tokens, at, options, env, self) ?? "";
        // v-pre keeps Vue from reading {{ }} in a diagram as a template.
        return `<pre class="mermaid" v-pre>${md.utils.escapeHtml(token.content)}</pre>`;
      };
      md.core.ruler.push("project-links", (state) => {
        const page = state.env.relativePath as string | undefined;
        if (!page) return;
        for (const token of state.tokens.flatMap(
          (block) => block.children ?? [],
        )) {
          if (token.type === "link_open")
            token.attrSet(
              "href",
              links.link(token.attrGet("href") ?? "", page),
            );
          if (token.type === "image")
            token.attrSet("src", links.image(token.attrGet("src") ?? "", page));
        }
      });
    },
  },
});
