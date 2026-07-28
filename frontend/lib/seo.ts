import type { Metadata } from "next";
import { siteConfig } from "@/lib/site-config";

export const SITE_URL = siteConfig.url;

/** Resolve a route path to an absolute URL. */
export function absoluteUrl(path = "/"): string {
  return new URL(path, SITE_URL).toString();
}

/**
 * True on production deploys only. Preview deployments are told not to index,
 * so a preview URL never competes with the canonical site in search results.
 */
export const isProduction =
  process.env.VERCEL_ENV === undefined || process.env.VERCEL_ENV === "production";

interface PageMetaInput {
  title: string;
  description: string;
  path: string;
  /** Omit the "| MacGet" suffix, for pages that carry the brand already. */
  absoluteTitle?: boolean;
}

/**
 * Every route gets a unique title, description, and canonical. Pages that
 * inherit a parent's metadata are the most common reason for "crawled,
 * currently not indexed".
 */
export function pageMetadata({
  title,
  description,
  path,
  absoluteTitle,
}: PageMetaInput): Metadata {
  const url = absoluteUrl(path);
  const fullTitle = absoluteTitle ? title : `${title} | ${siteConfig.name}`;

  return {
    title: absoluteTitle ? { absolute: title } : title,
    description,
    alternates: { canonical: url },
    openGraph: {
      title: fullTitle,
      description,
      url,
      siteName: siteConfig.name,
      type: "website",
    },
    twitter: {
      card: "summary_large_image",
      title: fullTitle,
      description,
    },
  };
}

type Schema = Record<string, unknown>;

export function softwareApplicationSchema(): Schema {
  return {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: siteConfig.name,
    description: siteConfig.tagline,
    url: SITE_URL,
    applicationCategory: "DeveloperApplication",
    applicationSubCategory: "Download Manager",
    operatingSystem: "macOS 26.4 or later",
    softwareVersion: siteConfig.version,
    downloadUrl: siteConfig.downloadUrl,
    license: siteConfig.licenseUrl,
    isAccessibleForFree: true,
    /* Confirms to search engines that the off-site profiles are the same product. */
    sameAs: [
      siteConfig.repoUrl,
      siteConfig.linkedinUrl,
      siteConfig.chromeWebStoreUrl,
    ],
    offers: {
      "@type": "Offer",
      price: "0",
      priceCurrency: "USD",
    },
    author: {
      "@type": "Person",
      name: "Suryansh",
      url: "https://github.com/Suryansh-Codes2209",
    },
  };
}

export function faqPageSchema(): Schema {
  return {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: siteConfig.faq.map((item) => ({
      "@type": "Question",
      name: item.q,
      acceptedAnswer: { "@type": "Answer", text: item.a },
    })),
  };
}

export function breadcrumbSchema(
  crumbs: Array<{ name: string; path: string }>,
): Schema {
  return {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: crumbs.map((crumb, i) => ({
      "@type": "ListItem",
      position: i + 1,
      name: crumb.name,
      item: absoluteUrl(crumb.path),
    })),
  };
}
