import { readFile } from "node:fs/promises";
import path from "node:path";
import { marked } from "marked";
import { PageShell } from "@/components/layout/PageShell";
import { Prose } from "@/components/layout/Prose";
import { pageMetadata } from "@/lib/seo";
import { siteConfig } from "@/lib/site-config";

export const metadata = pageMetadata({
  title: "Changelog",
  description:
    "Every released version of MacGet and what changed in it — the download engine, media and authenticated downloads, browser capture, and auto-updates.",
  path: "/changelog",
});

/**
 * Rendered from the repository's CHANGELOG.md, which `sync-assets` copies into
 * content/ during prebuild. Cutting a release updates this page; nobody has to
 * remember to mirror release notes onto the site.
 *
 * Plain markdown rather than MDX on purpose — the changelog contains text like
 * "< 16 KB", which an MDX parser would read as the start of a JSX tag.
 */
async function renderChangelog(): Promise<string> {
  const file = path.join(process.cwd(), "content", "CHANGELOG.md");
  const source = await readFile(file, "utf8");

  // The H1 and the intro line are replaced by this page's own header.
  const body = source.replace(/^#\s+Changelog\s*\n/, "");

  return marked.parse(body, { async: false, gfm: true });
}

export default async function ChangelogPage() {
  const html = await renderChangelog();

  return (
    <PageShell
      eyebrow="Releases"
      title="Changelog"
      lede={
        <>
          What shipped, when. Generated straight from the repository&apos;s
          CHANGELOG, so it can&apos;t drift from the actual releases.
        </>
      }
      meta={
        <>
          Current release: v{siteConfig.version} ·{" "}
          <a
            href={siteConfig.releasesUrl}
            target="_blank"
            rel="noreferrer noopener"
            className="text-brand-sky underline underline-offset-4 hover:text-frost"
          >
            Download from GitHub
          </a>
        </>
      }
    >
      <Prose
        className={[
          // Version headings act as section dividers.
          "[&_h2]:border-t [&_h2]:border-line [&_h2]:pt-10 [&_h2]:first:border-t-0 [&_h2]:first:pt-0",
          "[&_h3]:text-brand-sky",
          "[&_hr]:hidden",
        ].join(" ")}
      >
        <div dangerouslySetInnerHTML={{ __html: html }} />
      </Prose>
    </PageShell>
  );
}
