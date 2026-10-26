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

interface PageProps {
  params: Promise<{ slug?: string[] }>;
}

export default async function Page({ params }: PageProps) {
  const { slug } = await params;
  const page = source.getPage(slug);
  if (!page) notFound();

  const MDXContent = page.data.body;
  const related = relatedDocs(slug);

  return (
    <>
      <JsonLd
        schema={breadcrumbSchema([
          { name: "Home", path: "/" },
          { name: "Docs", path: "/docs" },
          { name: page.data.title, path: page.url },
        ])}
      />
      <DocsPage toc={page.data.toc} full={page.data.full}>
        <DocsTitle>{page.data.title}</DocsTitle>
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
    title: page.data.title,
    description:
      page.data.description ??
      "Documentation for MacGet, a native multi-threaded download manager for macOS.",
    path: page.url,
  });
}
