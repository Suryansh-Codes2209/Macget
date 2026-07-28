"use client";

import { motion } from "motion/react";
import {
  Activity,
  Apple,
  ArrowUpDown,
  BookOpen,
  Chrome,
  Clapperboard,
  Clipboard,
  Gauge,
  KeyRound,
  Layers,
  Lock,
  RotateCw,
  ShieldCheck,
  SlidersHorizontal,
  type LucideIcon,
} from "lucide-react";
import { fadeUp } from "@/lib/motion";

const ICONS: Record<string, LucideIcon> = {
  Activity,
  Apple,
  ArrowUpDown,
  BookOpen,
  Chrome,
  Clapperboard,
  Clipboard,
  Gauge,
  KeyRound,
  Layers,
  Lock,
  RotateCw,
  ShieldCheck,
  SlidersHorizontal,
};

interface FeatureCardProps {
  title: string;
  blurb: string;
  iconName: string;
}

export function FeatureCard({ title, blurb, iconName }: FeatureCardProps) {
  const Icon = ICONS[iconName] ?? Layers;
  return (
    <motion.div
      variants={fadeUp}
      whileHover={{ y: -4 }}
      transition={{ type: "spring", stiffness: 280, damping: 22 }}
      className="group relative overflow-hidden rounded-tile border border-line bg-surface/60 p-7 transition-colors hover:border-white/15 hover:bg-surface-2/80"
    >
      <div
        aria-hidden
        className="pointer-events-none absolute -right-8 -top-8 size-32 rounded-full bg-gradient-to-br from-brand-honey/10 via-brand-amber/10 to-transparent opacity-0 blur-2xl transition-opacity duration-500 group-hover:opacity-100"
      />
      <div className="relative">
        <div className="mb-5 inline-flex size-11 items-center justify-center rounded-2xl border border-line bg-white/[0.04] text-brand-honey">
          <Icon className="size-5" strokeWidth={2} />
        </div>
        <h3 className="text-lg font-semibold tracking-tight text-cream">
          {title}
        </h3>
        <p className="mt-2 text-sm leading-relaxed text-cream-dim">{blurb}</p>
      </div>
    </motion.div>
  );
}
