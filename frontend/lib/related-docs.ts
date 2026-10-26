import { source } from "@/lib/source";

/**
 * Hand-picked "read next" pages for each doc, keyed by slug ("" is /docs).
 *
 * The sidebar links every page to every other page identically, which tells a
 * crawler nothing about how they relate. Contextual links with descriptive
 * anchor text do — pages Search Console reported as "crawled, currently not
 * indexed" were the ones with no in-body links in or out.
 */
const RELATED: Record<string, string[]> = {
  "": ["installation", "first-launch", "adding-downloads", "engine-pipeline"],
  installation: ["first-launch", "updating", "browser-extension", "troubleshooting"],
  "first-launch": ["installation", "updating", "troubleshooting"],
  updating: ["installation", "file-locations", "troubleshooting"],
  "adding-downloads": ["browser-extension", "media-downloads", "torrents", "priorities-and-queue"],
  inspector: ["adaptive-concurrency", "engine-pipeline", "resume-semantics"],
  "media-downloads": ["adding-downloads", "organizing-downloads", "settings-reference", "troubleshooting"],
  "book-catalogs": ["adding-downloads", "organizing-downloads", "media-downloads"],
  torrents: ["priorities-and-queue", "resume-semantics", "settings-reference", "troubleshooting"],
  "authenticated-downloads": ["browser-extension", "file-locations", "troubleshooting"],
  "browser-extension": ["adding-downloads", "authenticated-downloads", "media-downloads"],
  "priorities-and-queue": ["adaptive-concurrency", "torrents", "settings-reference"],
  "organizing-downloads": ["file-locations", "checksums", "settings-reference"],
  checksums: ["engine-pipeline", "resume-semantics", "organizing-downloads"],
  "settings-reference": ["priorities-and-queue", "adaptive-concurrency", "organizing-downloads", "torrents"],
  "engine-pipeline": ["adaptive-concurrency", "resume-semantics", "inspector", "checksums"],
  "adaptive-concurrency": ["engine-pipeline", "inspector", "priorities-and-queue"],
  "resume-semantics": ["engine-pipeline", "file-locations", "troubleshooting"],
  "file-locations": ["settings-reference", "resume-semantics", "troubleshooting"],
  troubleshooting: ["first-launch", "resume-semantics", "authenticated-downloads", "file-locations"],
};

export function relatedDocs(slug: string[] = []) {
  return (RELATED[slug.join("/")] ?? [])
    .map((s) => source.getPage([s]))
    .filter((page) => page !== undefined);
}
