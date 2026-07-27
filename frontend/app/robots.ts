import type { MetadataRoute } from "next";
import { absoluteUrl, isProduction } from "@/lib/seo";

export default function robots(): MetadataRoute.Robots {
  // Preview deployments are excluded outright so they can never be indexed
  // alongside — or instead of — the canonical site.
  if (!isProduction) {
    return { rules: { userAgent: "*", disallow: "/" } };
  }

  return {
    rules: { userAgent: "*", allow: "/" },
    sitemap: absoluteUrl("/sitemap.xml"),
    host: absoluteUrl("/"),
  };
}
