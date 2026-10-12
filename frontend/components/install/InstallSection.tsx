import Link from "next/link";
import { ArrowDownToLine } from "lucide-react";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { CopyCommand } from "@/components/ui/CopyCommand";
import { GradientButton } from "@/components/ui/GradientButton";
import { siteConfig } from "@/lib/site-config";

/**
 * Two ways in, side by side. MacGet ships un-notarized, so the DMG path meets
 * a Gatekeeper dialog that reads like a malware alert — the steps live right
 * next to the button so nobody hits it unprepared.
 */
export function InstallSection() {
  return (
    <section
      id="install"
      aria-labelledby="install-heading"
      className="relative scroll-mt-16 py-20 sm:py-28"
    >
      <div className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[520px] bg-radial-glow" />
      <div className="mx-auto max-w-6xl px-6 lg:px-10">
        <SectionHeading
          id="install-heading"
          align="center"
          title="Get MacGet"
          lede={`Free and open source. Requires an Apple silicon Mac on ${siteConfig.minOS} or later.`}
        />

        <div className="mt-14 grid gap-6 lg:grid-cols-2">
          <div className="flex min-w-0 flex-col rounded-tile border border-brand-amber/30 bg-surface/70 p-7 sm:p-9">
            <div className="flex items-center justify-between gap-4">
              <h3 className="text-xl font-semibold tracking-tight text-cream">
                Homebrew
              </h3>
              <span className="rounded-pill bg-brand-amber/15 px-2.5 py-1 text-xs text-brand-honey">
                Recommended
              </span>
            </div>
            <p className="mt-3 text-sm leading-relaxed text-cream-dim">
              One command. No Gatekeeper prompt, and{" "}
              <code className="font-mono text-cream">brew upgrade</code> keeps
              it current alongside the built-in updater.
            </p>
            <CopyCommand
              command={siteConfig.brewCommand}
              label="Copy the Homebrew install command"
              className="mt-6"
            />
            <p className="mt-auto pt-6 text-sm leading-relaxed text-mute">
              Installs {siteConfig.binary}.app into Applications and clears the
              download quarantine flag, so it opens on the first try. No
              Homebrew yet?{" "}
              <a
                href="https://brew.sh"
                target="_blank"
                rel="noreferrer noopener"
                className="text-cream-dim underline decoration-line underline-offset-4 hover:text-cream"
              >
                brew.sh
              </a>
            </p>
          </div>

          <div className="flex min-w-0 flex-col rounded-tile border border-line bg-surface/40 p-7 sm:p-9">
            <h3 className="text-xl font-semibold tracking-tight text-cream">
              Download the app
            </h3>
            <p className="mt-3 text-sm leading-relaxed text-cream-dim">
              MacGet isn&apos;t notarized (that needs a paid Apple account), so
              macOS asks once on first launch:
            </p>
            <ol className="mt-5 space-y-3">
              {siteConfig.firstLaunch.map((step, i) => (
                <li key={step} className="flex gap-3 text-sm leading-relaxed text-cream-dim">
                  <span className="flex size-6 shrink-0 items-center justify-center rounded-full border border-line text-xs tabular-nums text-cream">
                    {i + 1}
                  </span>
                  {step}
                </li>
              ))}
            </ol>
            <div className="mt-7 flex flex-col gap-3 sm:flex-row sm:items-center">
              <GradientButton href={siteConfig.downloadUrl} external>
                <ArrowDownToLine className="size-4" strokeWidth={2.4} />
                Download v{siteConfig.version}
              </GradientButton>
              <Link
                href="/install"
                className="text-center text-sm text-cream-dim underline decoration-line underline-offset-4 hover:text-cream sm:text-left"
              >
                Full install guide
              </Link>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
