import Link from "next/link";
import { notFound } from "next/navigation";
import {
  DocsBody,
  DocsDescription,
  DocsPage,
  DocsTitle,
} from "fumadocs-ui/page";
import { Card, Cards } from "fumadocs-ui/components/card";
import { source } from "@/lib/source";
import { relatedDocs } from "@/lib/related-docs";
import { getMDXComponents } from "@/mdx-components";
import { JsonLd } from "@/components/seo/JsonLd";
import { breadcrumbSchema, pageMetadata } from "@/lib/seo";

/*
 * The index page keeps "Introduction" as its sidebar label (its frontmatter
 * title), but its H1 and title tag say what the whole section is.
 */
const DOCS_INDEX_HEADING = "MacGet documentation";

function isDocsIndex(slug?: string[]) {
  return !slug || slug.length === 0;
}

interface PageProps {
  params: Promise<{ slug?: string[] }>;
}

export default async function Page({ params }: PageProps) {
  const { slug } = await params;
  const page = source.getPage(slug);
  if (!page) notFound();

  const MDXContent = page.data.body;
  const related = relatedDocs(slug);
  const heading = isDocsIndex(slug) ? DOCS_INDEX_HEADING : page.data.title;

  return (
    <>
      <JsonLd
        schema={breadcrumbSchema([
          { name: "Home", path: "/" },
          { name: "Docs", path: "/docs" },
          ...(isDocsIndex(slug) ? [] : [{ name: page.data.title, path: page.url }]),
        ])}
      />
      <DocsPage
        toc={page.data.toc}
        full={page.data.full}
        // The docs tree is flat, so Fumadocs' own trail would only show the page
        // title. Render Home › Docs › Page instead, matching the BreadcrumbList above.
        breadcrumb={{ enabled: false }}
      >
        {slug && slug.length > 0 && (
          <nav aria-label="Breadcrumb" className="mb-2 text-sm text-fd-muted-foreground">
            <ol className="flex flex-wrap items-center gap-1.5">
              <li><Link href="/" className="hover:text-fd-foreground">Home</Link></li>
              <li aria-hidden>›</li>
              <li><Link href="/docs" className="hover:text-fd-foreground">Docs</Link></li>
              <li aria-hidden>›</li>
              <li aria-current="page" className="text-fd-primary">{page.data.title}</li>
            </ol>
          </nav>
        )}
        <DocsTitle>{heading}</DocsTitle>
        <DocsDescription>{page.data.description}</DocsDescription>
        <DocsBody>
          <MDXContent components={getMDXComponents()} />
          {related.length > 0 && (
            <>
              <h2 id="related">Related</h2>
              <Cards>
                {related.map((r) => (
                  <Card
                    key={r.url}
                    href={r.url}
                    title={r.data.title}
                    description={r.data.description}
                  />
                ))}
              </Cards>
            </>
          )}
          {/* Every guide links the install page, so each one passes it some weight. */}
          {page.url !== "/install" && (
            <p className="mt-10 rounded-xl border border-fd-border bg-fd-card p-4 text-sm">
              New to MacGet?{" "}
              <Link href="/install" className="font-medium">
                Install MacGet on your Mac
              </Link>{" "}
              with Homebrew or the signed DMG. It takes about a minute.
            </p>
          )}
        </DocsBody>
      </DocsPage>
    </>
  );
}

export function generateStaticParams() {
  return source.generateParams();
}

export async function generateMetadata({ params }: PageProps) {
  const { slug } = await params;
  const page = source.getPage(slug);
  if (!page) notFound();

  return pageMetadata({
    title: isDocsIndex(slug) ? DOCS_INDEX_HEADING : page.data.title,
    description:
      page.data.description ??
      "Documentation for MacGet, a native multi-threaded download manager for macOS.",
    path: page.url,
    absoluteTitle: isDocsIndex(slug),
  });
}
