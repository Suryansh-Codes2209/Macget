"use client";

import { motion } from "motion/react";
import { ArrowDownToLine, Github } from "lucide-react";
import { ChunkVisualization } from "./ChunkVisualization";
import { FloatingStatCards } from "./FloatingStatCards";
import { GradientButton } from "@/components/ui/GradientButton";
import { siteConfig } from "@/lib/site-config";
import { easeEmphasized } from "@/lib/motion";

export function Hero() {
  return (
    <section className="relative isolate overflow-hidden pt-32 pb-20 sm:pt-36 sm:pb-28">
      {/* Ambient glows */}
      <div className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[640px] bg-radial-glow" />
      <div className="pointer-events-none absolute -top-40 left-1/2 -z-10 h-[600px] w-[800px] -translate-x-1/2 rounded-full bg-brand-amber/10 blur-3xl" />

      <div className="mx-auto grid max-w-7xl gap-16 px-6 lg:grid-cols-[1.05fr_1fr] lg:items-center lg:gap-12 lg:px-10">
        {/* Copy column */}
        <div>
          <motion.div
            initial={{ opacity: 0, y: 12 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, ease: easeEmphasized }}
            className="inline-flex items-center gap-2 rounded-pill border border-line bg-white/[0.04] px-3 py-1 text-xs font-medium text-cream-dim"
          >
            <span className="relative flex size-1.5">
              <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-brand-honey opacity-75" />
              <span className="relative inline-flex size-1.5 rounded-full bg-brand-honey" />
            </span>
            v{siteConfig.version} · Native for {siteConfig.minOS}
          </motion.div>

          <motion.h1
            initial={{ opacity: 0, y: 24 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, ease: easeEmphasized, delay: 0.05 }}
            className="mt-6 text-balance text-5xl font-semibold leading-[1.02] tracking-tight text-cream sm:text-6xl lg:text-7xl"
          >
            <span className="block">{siteConfig.heroHeadline[0]}</span>
            <span className="block bg-gradient-to-r from-brand-honey via-brand-amber to-brand-umber bg-clip-text text-transparent">
              {siteConfig.heroHeadline[1]}
            </span>
          </motion.h1>

          <motion.p
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, ease: easeEmphasized, delay: 0.15 }}
            className="mt-6 max-w-xl text-base leading-relaxed text-cream-dim sm:text-lg"
          >
            {siteConfig.heroSub}
          </motion.p>

          <motion.div
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, ease: easeEmphasized, delay: 0.25 }}
            className="mt-9 flex flex-wrap items-center gap-3"
          >
            <GradientButton
              href={siteConfig.downloadUrl}
              external
              size="lg"
              variant="primary"
            >
              <ArrowDownToLine className="size-5" strokeWidth={2.4} />
              Download for macOS
            </GradientButton>
            <GradientButton
              href={siteConfig.repoUrl}
              external
              size="lg"
              variant="ghost"
            >
              <Github className="size-5" strokeWidth={2} />
              View on GitHub
            </GradientButton>
          </motion.div>

          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.7, delay: 0.4 }}
            className="mt-6 flex flex-wrap items-center gap-x-5 gap-y-2 text-sm text-mute"
          >
            <span>Free · MIT licensed</span>
            <span className="hidden h-1 w-1 rounded-full bg-mute/60 sm:inline-block" />
            <span>Apple silicon native</span>
            <span className="hidden h-1 w-1 rounded-full bg-mute/60 sm:inline-block" />
            <span>Zero telemetry</span>
          </motion.div>
        </div>

        {/* Visualization column */}
        <div className="relative mx-auto w-full max-w-[560px]">
          <FloatingStatCards />
          <motion.div
            initial={{ opacity: 0, scale: 0.96 }}
            animate={{ opacity: 1, scale: 1 }}
            transition={{ duration: 0.9, ease: easeEmphasized, delay: 0.1 }}
            className="relative z-0"
          >
            <ChunkVisualization />
          </motion.div>
        </div>
      </div>
    </section>
  );
}
