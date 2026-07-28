import Link from "next/link";
import { Chrome, ShieldCheck } from "lucide-react";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { MotionInView, MotionItem } from "@/components/ui/MotionInView";
import { GradientButton } from "@/components/ui/GradientButton";
import { siteConfig } from "@/lib/site-config";

/**
 * The extension's one real differentiator is *what survives the handoff* — a
 * captured download keeps the cookies and referrer that made it work in the
 * browser. So the section shows the payload as a manifest of the fields the
 * extension actually sends, rather than a mock of its popup: the same argument
 * the inspector section makes, that showing the real thing beats illustrating it.
 */
export function BrowserCapture() {
  return (
    <section
      id="extension"
      aria-labelledby="extension-heading"
      className="relative py-28 sm:py-36"
    >
      <div className="mx-auto max-w-7xl px-6 lg:px-10">
        <SectionHeading
          eyebrow="Browser capture"
          title={
            <span id="extension-heading">
              Your browser starts it.
              <br className="hidden sm:inline" /> MacGet finishes it.
            </span>
          }
          lede="Install the extension and downloads leave the browser's single stream for MacGet's engine — carrying the cookies and referrer that made them work, so a file behind a login stays downloadable."
        />

        {/* Stacked on mobile this grid is taller than the viewport, so the
            default 30%-visible trigger can never fire and the cards would stay
            at their hidden opacity. */}
        <MotionInView
          amount={0.05}
          className="mt-16 grid items-start gap-6 lg:grid-cols-12"
        >
          <MotionItem className="lg:col-span-7">
            <div className="rounded-tile border border-line bg-surface/60 p-7 sm:p-9">
              <div className="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
                <h3 className="text-lg font-semibold tracking-tight text-cream">
                  Handed over with every capture
                </h3>
                <span className="font-mono text-xs text-mute">
                  local native messaging
                </span>
              </div>

              <dl className="mt-7 divide-y divide-line/70">
                {siteConfig.extension.payload.map((row) => (
                  <div
                    key={row.field}
                    className="grid gap-1 py-4 first:pt-0 last:pb-0 sm:grid-cols-[8.5rem_1fr] sm:gap-6"
                  >
                    <dt className="font-mono text-sm text-brand-honey sm:pt-px sm:text-right">
                      {row.field}
                    </dt>
                    <dd className="text-sm leading-relaxed text-cream-dim sm:border-l sm:border-line sm:pl-6">
                      {row.note}
                    </dd>
                  </div>
                ))}
              </dl>

              <p className="mt-7 border-t border-line pt-6 text-sm leading-relaxed text-mute">
                The handoff runs over a local channel to a helper inside{" "}
                {siteConfig.binary}.app. The extension contains no code that
                contacts a remote server —{" "}
                <Link
                  href="/privacy"
                  className="text-cream-dim underline underline-offset-4 transition-colors hover:text-cream"
                >
                  see the privacy policy
                </Link>
                .
              </p>
            </div>
          </MotionItem>

          <MotionItem className="flex flex-col gap-6 lg:col-span-5">
            <div className="rounded-tile border border-line bg-surface/40 p-7">
              <ShieldCheck className="size-5 text-brand-honey" />
              <h3 className="mt-4 text-lg font-semibold tracking-tight text-cream">
                Nothing gets lost in the handoff
              </h3>
              <p className="mt-2 text-sm leading-relaxed text-cream-dim">
                The browser&apos;s own download is cancelled only after MacGet
                confirms it has the file. Quit MacGet, turn capture off, skip the
                install — the worst case is that your browser downloads it the
                way it always did.
              </p>
            </div>

            <div className="rounded-tile border border-line bg-surface/40 p-7">
              <h3 className="text-lg font-semibold tracking-tight text-cream">
                Add it to your browser
              </h3>
              <p className="mt-2 text-sm leading-relaxed text-cream-dim">
                Published on the Chrome Web Store — one click on Chrome, Edge,
                and Brave. Firefox loads it from the repository.
              </p>

              <div className="mt-6 flex flex-col gap-3 sm:flex-row lg:flex-col xl:flex-row">
                <GradientButton
                  href={siteConfig.chromeWebStoreUrl}
                  external
                  className="justify-center"
                >
                  <Chrome className="size-4" />
                  Add to Chrome
                </GradientButton>
                <Link
                  href="/docs/browser-extension"
                  className="inline-flex items-center justify-center gap-2 rounded-pill border border-line bg-white/[0.04] px-5 py-2.5 text-sm font-medium tracking-tight text-cream transition-colors hover:border-white/20 hover:bg-white/[0.08]"
                >
                  Firefox &amp; setup guide
                </Link>
              </div>

              <ul className="mt-6 flex flex-wrap gap-2" aria-label="Supported browsers">
                {siteConfig.extension.browsers.map((browser) => (
                  <li
                    key={browser}
                    className="rounded-pill border border-line px-3 py-1 text-xs text-mute"
                  >
                    {browser}
                  </li>
                ))}
              </ul>
            </div>
          </MotionItem>
        </MotionInView>
      </div>
    </section>
  );
}
