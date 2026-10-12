"use client";

import Link from "next/link";
import { motion } from "motion/react";
import { ArrowDownToLine, Github } from "lucide-react";
import { LaunchFilm } from "./LaunchFilm";
import { CopyCommand } from "@/components/ui/CopyCommand";
import { GradientButton } from "@/components/ui/GradientButton";
import { siteConfig } from "@/lib/site-config";
import { easeEmphasized } from "@/lib/motion";

/** The page's one orchestrated motion moment: copy, then the film rises in. */
const rise = (delay: number) => ({
  initial: { opacity: 0, y: 16 },
  animate: { opacity: 1, y: 0 },
  transition: { duration: 0.7, ease: easeEmphasized, delay },
});

export function Hero() {
  return (
    <section
      aria-labelledby="hero-heading"
      className="relative isolate overflow-hidden pt-32 pb-16 sm:pt-40 sm:pb-24"
    >
      <div className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[720px] bg-radial-glow" />

      <div className="mx-auto max-w-6xl px-6 lg:px-10">
        <div className="mx-auto max-w-3xl text-center">
          <motion.p
            {...rise(0)}
            className="inline-flex items-center gap-2 rounded-pill border border-line bg-white/[0.04] px-3 py-1 text-xs text-cream-dim"
          >
            <span className="size-1.5 rounded-full bg-success" />
            Version {siteConfig.version} for Apple silicon, {siteConfig.minOS}+
          </motion.p>

          <motion.h1
            id="hero-heading"
            {...rise(0.05)}
            className="mt-6 text-balance text-5xl font-semibold leading-[1.02] tracking-tight text-cream sm:text-7xl"
          >
            {siteConfig.heroHeadline.join(" ")}
          </motion.h1>

          <motion.p
            {...rise(0.12)}
            className="mx-auto mt-6 max-w-2xl text-pretty text-base leading-relaxed text-cream-dim sm:text-lg"
          >
            {siteConfig.heroSub}
          </motion.p>

          <motion.div
            {...rise(0.2)}
            className="mt-9 flex flex-col items-stretch justify-center gap-3 sm:flex-row sm:items-center"
          >
            <GradientButton href={siteConfig.downloadUrl} external size="lg">
              <ArrowDownToLine className="size-5" strokeWidth={2.4} />
              Download for Mac
            </GradientButton>
            <GradientButton
              href={siteConfig.repoUrl}
              external
              size="lg"
              variant="ghost"
            >
              <Github className="size-5" strokeWidth={2} />
              Source on GitHub
            </GradientButton>
          </motion.div>

          <motion.div {...rise(0.26)} className="mx-auto mt-5 max-w-lg text-left">
            <CopyCommand
              command={siteConfig.brewCommand}
              label="Copy the Homebrew install command"
            />
            <p className="mt-2.5 text-center text-sm text-mute">
              Homebrew skips the first-launch warning.{" "}
              <Link
                href="/#install"
                className="text-cream-dim underline decoration-line underline-offset-4 transition-colors hover:text-cream"
              >
                Install options
              </Link>
            </p>
          </motion.div>
        </div>

        <motion.div
          initial={{ opacity: 0, y: 40, scale: 0.98 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          transition={{ duration: 1, ease: easeEmphasized, delay: 0.35 }}
          className="mt-16 sm:mt-20"
        >
          <LaunchFilm />
        </motion.div>

        <ul className="mx-auto mt-12 grid max-w-4xl grid-cols-2 gap-px overflow-hidden rounded-card border border-line bg-line sm:grid-cols-4">
          {[
            ["16", "connections per file"],
            ["2+", "networks at once, like Wi-Fi and your phone"],
            ["0", "analytics, accounts or telemetry"],
            ["MIT", "licensed, free forever"],
          ].map(([value, label]) => (
            <li key={label} className="bg-ink px-5 py-5 text-center">
              <div className="text-2xl font-semibold tracking-tight text-cream">
                {value}
              </div>
              <div className="mt-1 text-xs leading-snug text-mute">{label}</div>
            </li>
          ))}
        </ul>

        <div className="mt-10 flex justify-center">
          <a
            href="https://www.producthunt.com/products/macget?embed=true&utm_source=badge-featured&utm_medium=badge&utm_campaign=badge-macget"
            target="_blank"
            rel="noopener noreferrer"
            className="inline-block opacity-80 transition-opacity hover:opacity-100"
          >
            {/* Product Hunt serves the badge as an SVG from its own host, so
                next/image would need `dangerouslyAllowSVG` plus a remote
                pattern to render one fixed 250×54 asset. */}
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1219547&theme=dark&t=1786375523045"
              alt="MacGet - Free, open-source multi-threaded download manager for Mac | Product Hunt"
              width={250}
              height={54}
              className="h-[54px] w-[250px]"
            />
          </a>
        </div>
      </div>
    </section>
  );
}
