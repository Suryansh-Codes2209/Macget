import Link from "next/link";
import { ShieldAlert } from "lucide-react";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { MotionInView } from "@/components/ui/MotionInView";
import { siteConfig } from "@/lib/site-config";

/**
 * Shown directly under the download CTA. MacGet ships un-notarized, so a user
 * who downloads without warning meets a Gatekeeper dialog that reads like a
 * malware alert. Setting the expectation here is the whole point.
 */
export function FirstLaunchStrip() {
  return (
    <section
      id="first-launch"
      aria-labelledby="first-launch-heading"
      className="relative py-24 sm:py-28"
    >
      <div className="mx-auto max-w-7xl px-6 lg:px-10">
        <SectionHeading
          eyebrow="Before you install"
          title={
            <span id="first-launch-heading">
              One prompt on first launch.
              <br className="hidden sm:inline" /> Then never again.
            </span>
          }
          lede={
            <>
              MacGet is free and <strong className="text-frost">not notarized</strong> —
              notarization needs a paid Apple Developer account. macOS will stop the
              first launch, and here is exactly how to get past it.
            </>
          }
        />

        <MotionInView className="mt-14 grid gap-5 md:grid-cols-3">
          {siteConfig.firstLaunch.map((step, i) => (
            <div
              key={step.title}
              className="relative rounded-tile border border-line bg-surface/60 p-7"
            >
              <div className="mb-5 inline-flex size-9 items-center justify-center rounded-xl border border-line bg-white/[0.04] font-mono text-sm text-brand-sky">
                {i + 1}
              </div>
              <h3 className="text-base font-semibold tracking-tight text-frost">
                {step.title}
              </h3>
              <p className="mt-2 text-sm leading-relaxed text-frost-dim">
                {step.detail}
              </p>
            </div>
          ))}
        </MotionInView>

        <div className="mt-8 flex flex-col gap-4 rounded-tile border border-line bg-surface/40 p-7 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-start gap-3">
            <ShieldAlert className="mt-0.5 size-5 shrink-0 text-brand-sky" />
            <div>
              <p className="text-sm font-medium text-frost">
                Prefer the terminal?
              </p>
              <p className="mt-1 text-sm text-frost-dim">
                Clearing the quarantine flag skips the dialog entirely:
              </p>
              <code className="mt-3 block overflow-x-auto rounded-xl border border-line bg-abyss px-4 py-3 font-mono text-xs text-frost-dim">
                xattr -dr com.apple.quarantine /Applications/{siteConfig.binary}.app
              </code>
            </div>
          </div>
          <Link
            href="/install"
            className="shrink-0 rounded-pill border border-line bg-white/[0.04] px-5 py-2.5 text-sm text-frost transition-colors hover:border-white/20 hover:bg-white/[0.08]"
          >
            Full install guide
          </Link>
        </div>
      </div>
    </section>
  );
}
