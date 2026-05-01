"use client";

import { motion, useScroll, useTransform } from "motion/react";
import { useRef } from "react";
import { Check } from "lucide-react";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { siteConfig } from "@/lib/site-config";

export function HowItWorks() {
  const ref = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({
    target: ref,
    offset: ["start 70%", "end 30%"],
  });

  const lineHeight = useTransform(scrollYProgress, [0, 1], ["0%", "100%"]);

  return (
    <section
      id="how"
      aria-labelledby="how-heading"
      className="relative py-28 sm:py-36"
    >
      <div className="mx-auto max-w-7xl px-6 lg:px-10">
        <SectionHeading
          eyebrow="The pipeline"
          title={
            <span id="how-heading">
              Probe. Plan. Stream. Finalize.
            </span>
          }
          lede="Every download walks through the same four stages. Each one is its own actor — failure in one doesn't corrupt the others."
        />

        <div ref={ref} className="relative mt-20 max-w-3xl">
          {/* Vertical guide line */}
          <div
            aria-hidden
            className="absolute left-6 top-2 h-[calc(100%-1rem)] w-px bg-line sm:left-7"
          />
          <motion.div
            aria-hidden
            style={{ height: lineHeight }}
            className="absolute left-6 top-2 w-px bg-gradient-to-b from-brand-sky via-brand-blue to-brand-cobalt sm:left-7"
          />

          <ol className="space-y-12">
            {siteConfig.pipeline.map((step, i) => {
              const segStart = i / siteConfig.pipeline.length;
              const segActive = (i + 0.4) / siteConfig.pipeline.length;
              return (
                <PipelineStep
                  key={step.step}
                  index={i + 1}
                  step={step.step}
                  detail={step.detail}
                  progress={scrollYProgress}
                  activatesAt={segStart}
                  fillsAt={segActive}
                />
              );
            })}
          </ol>
        </div>
      </div>
    </section>
  );
}

function PipelineStep({
  index,
  step,
  detail,
  progress,
  activatesAt,
  fillsAt,
}: {
  index: number;
  step: string;
  detail: string;
  progress: ReturnType<typeof useScroll>["scrollYProgress"];
  activatesAt: number;
  fillsAt: number;
}) {
  const opacity = useTransform(progress, [activatesAt, fillsAt], [0.35, 1]);
  const x = useTransform(progress, [activatesAt, fillsAt], [-8, 0]);
  const dotScale = useTransform(progress, [activatesAt, fillsAt], [0.85, 1]);
  const dotBg = useTransform(
    progress,
    [activatesAt, fillsAt],
    ["rgba(216,232,255,0.06)", "rgba(10,132,255,1)"],
  );
  const checkOpacity = useTransform(progress, [fillsAt - 0.05, fillsAt], [0, 1]);

  return (
    <motion.li
      style={{ opacity, x }}
      className="relative flex items-start gap-6 pl-2"
    >
      <motion.div
        style={{ scale: dotScale, backgroundColor: dotBg }}
        className="relative z-10 flex size-12 shrink-0 items-center justify-center rounded-full border border-line shadow-[0_8px_24px_rgba(10,132,255,0.25)]"
      >
        <span className="absolute font-mono text-xs font-semibold text-frost">
          {String(index).padStart(2, "0")}
        </span>
        <motion.span
          style={{ opacity: checkOpacity }}
          className="absolute inset-0 flex items-center justify-center rounded-full bg-brand-blue text-frost"
        >
          <Check className="size-5" strokeWidth={3} />
        </motion.span>
      </motion.div>
      <div className="flex-1 pt-1">
        <h3 className="text-xl font-semibold tracking-tight text-frost">
          {step}
        </h3>
        <p className="mt-2 max-w-xl text-sm leading-relaxed text-frost-dim sm:text-base">
          {detail}
        </p>
      </div>
    </motion.li>
  );
}
