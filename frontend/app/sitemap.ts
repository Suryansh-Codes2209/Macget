import type { MetadataRoute } from "next";
import { source } from "@/lib/source";
import { absoluteUrl } from "@/lib/seo";

/**
 * Marketing routes are listed explicitly; docs routes are read from the
 * fumadocs source, so a new MDX file is in the sitemap the moment it exists.
 */
export default function sitemap(): MetadataRoute.Sitemap {
  const marketing: MetadataRoute.Sitemap = [
    { url: absoluteUrl("/"), changeFrequency: "monthly", priority: 1 },
    { url: absoluteUrl("/install"), changeFrequency: "monthly", priority: 0.9 },
    { url: absoluteUrl("/changelog"), changeFrequency: "weekly", priority: 0.7 },
    { url: absoluteUrl("/privacy"), changeFrequency: "yearly", priority: 0.3 },
  ];

  const docs: MetadataRoute.Sitemap = source.getPages().map((page) => ({
    url: absoluteUrl(page.url),
    changeFrequency: "monthly",
    priority: page.url === "/docs" ? 0.9 : 0.6,
  }));

  return [...marketing, ...docs];
}
