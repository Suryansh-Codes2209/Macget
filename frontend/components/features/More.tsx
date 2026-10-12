import Link from "next/link";
import {
  ArrowUpDown,
  BookOpen,
  Chrome,
  Clapperboard,
  Clipboard,
  FolderTree,
  KeyRound,
  Layers,
  RefreshCw,
  SlidersHorizontal,
  type LucideIcon,
} from "lucide-react";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { GradientButton } from "@/components/ui/GradientButton";
import { siteConfig } from "@/lib/site-config";

const ICONS: Record<string, LucideIcon> = {
  ArrowUpDown,
  BookOpen,
  Clapperboard,
  Clipboard,
  FolderTree,
  KeyRound,
  RefreshCw,
  SlidersHorizontal,
};

/**
 * Everything beyond the engine. The browser extension leads as a wide panel
 * because it's the one item with an install step of its own; the rest is a
 * plain icon list — one sentence each, with the docs carrying the detail.
 */
export function More() {
  return (
    <section
      id="more"
      aria-labelledby="more-heading"
      className="relative scroll-mt-16 py-20 sm:py-28"
    >
      <div className="mx-auto max-w-6xl px-6 lg:px-10">
        <SectionHeading
          id="more-heading"
          title="And everything else you'd expect"
          lede="Video, ebooks, torrents and logins all land in the same queue."
        />

        <div
          id="extension"
          className="mt-14 grid scroll-mt-24 gap-8 rounded-tile border border-line bg-surface/60 p-7 sm:p-9 lg:grid-cols-[1.2fr_1fr] lg:items-center"
        >
          <div>
            <h3 className="text-2xl font-semibold tracking-tight text-cream">
              Click download in your browser. MacGet takes it from there.
            </h3>
            <p className="mt-3 text-pretty leading-relaxed text-cream-dim">
              The extension hands each download to MacGet with your cookies and
              referrer, so files behind a login keep working. The browser&apos;s
              own download is cancelled only once MacGet confirms it has the
              file — if MacGet isn&apos;t running, nothing changes.
            </p>
            <div className="mt-6 flex flex-col gap-3 sm:flex-row">
              <GradientButton href={siteConfig.chromeWebStoreUrl} external>
                <Chrome className="size-4" />
                Add to Chrome
              </GradientButton>
              <GradientButton href="/docs/browser-extension" variant="ghost">
                Edge, Brave and Firefox setup
              </GradientButton>
            </div>
          </div>

          <div className="rounded-card border border-line bg-abyss p-5">
            <p className="text-sm text-cream-dim">
              Sent to MacGet with every capture, over a local channel only:
            </p>
            <ul className="mt-4 flex flex-wrap gap-2">
              {siteConfig.extension.payload.map((field) => (
                <li
                  key={field}
                  className="rounded-md border border-brand-honey/25 bg-brand-honey/[0.07] px-2.5 py-1 font-mono text-xs text-brand-honey"
                >
                  {field}
                </li>
              ))}
            </ul>
            <p className="mt-4 text-xs leading-relaxed text-mute">
              The extension never contacts a remote server.{" "}
              <Link
                href="/privacy"
                className="text-cream-dim underline underline-offset-4 hover:text-cream"
              >
                Privacy policy
              </Link>
            </p>
          </div>
        </div>

        <ul className="mt-12 grid gap-x-10 gap-y-9 sm:grid-cols-2 lg:grid-cols-4">
          {siteConfig.more.map((item) => {
            const Icon = ICONS[item.icon] ?? Layers;
            return (
              <li key={item.title}>
                <div className="flex items-center gap-3">
                  <span className="inline-flex size-9 items-center justify-center rounded-xl border border-line bg-white/[0.04] text-brand-honey">
                    <Icon className="size-[18px]" strokeWidth={2} />
                  </span>
                  {"tag" in item && (
                    <span className="rounded-pill border border-line px-2 py-0.5 text-[11px] text-mute">
                      {item.tag}
                    </span>
                  )}
                </div>
                <h3 className="mt-4 font-semibold tracking-tight text-cream">
                  {item.title}
                </h3>
                <p className="mt-1.5 text-sm leading-relaxed text-cream-dim">
                  {item.blurb}
                </p>
              </li>
            );
          })}
        </ul>
      </div>
    </section>
  );
}
