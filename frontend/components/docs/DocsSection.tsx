import Link from "next/link";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { source } from "@/lib/source";

/**
 * The six guides most people need, linked from the homepage body (not just the
 * nav/footer). In-body links with descriptive text tell crawlers which docs
 * matter; titles and descriptions come straight from each page's frontmatter.
 */
const GUIDES = ["installation", "browser-extension", "media-downloads", "torrents", "adaptive-concurrency", "troubleshooting"];

export function DocsSection() {
  const pages = GUIDES.map((slug) => source.getPage([slug])).filter((p) => p !== undefined);

  return (
    <section id="docs" aria-labelledby="docs-heading" className="relative scroll-mt-16 py-20 sm:py-28">
      <div className="mx-auto max-w-6xl px-6 lg:px-10">
        <SectionHeading
          id="docs-heading"
          title="Documentation"
          lede={
            <>
              Start with these guides, or browse{" "}
              <Link href="/docs" className="text-cream underline decoration-line underline-offset-4 hover:decoration-cream/40">
                all MacGet docs
              </Link>
              .
            </>
          }
        />
        <ul className="mt-12 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {pages.map((page) => (
            <li key={page.url}>
              <Link
                href={page.url}
                className="group block h-full rounded-2xl border border-line bg-ink/60 p-6 transition-colors hover:border-brand-amber/50"
              >
                <h3 className="font-semibold tracking-tight text-cream group-hover:text-brand-honey">{page.data.title}</h3>
                {page.data.description && <p className="mt-2 text-sm leading-relaxed text-cream-dim">{page.data.description}</p>}
                <span className="mt-4 inline-block text-sm text-brand-honey">Read the guide →</span>
              </Link>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}
