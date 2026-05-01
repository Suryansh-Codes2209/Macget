"use client";

import {
  motion,
  useMotionValue,
  useReducedMotion,
  useSpring,
  useTransform,
  type MotionValue,
} from "motion/react";
import { Layers, RotateCcw, ShieldCheck } from "lucide-react";
import { useEffect, useRef } from "react";
import { GlassCard } from "@/components/ui/GlassCard";
import { cardEntry, springSnappy, staggerParent } from "@/lib/motion";

interface CardSpec {
  position: string;
  depth: number;
  icon: React.ReactNode;
  eyebrow: string;
  title: string;
  meta?: string;
}

const CARDS: CardSpec[] = [
  {
    position: "top-2 -left-4 sm:-left-12 md:-left-16",
    depth: 14,
    icon: <Layers className="size-4" strokeWidth={2.2} />,
    eyebrow: "Threads",
    title: "16 parallel chunks",
    meta: "max per file",
  },
  {
    position: "top-1/3 -right-4 sm:-right-10 md:-right-14",
    depth: 20,
    icon: <RotateCcw className="size-4" strokeWidth={2.2} />,
    eyebrow: "Resume",
    title: "Across restarts",
    meta: "If-Range ✓",
  },
  {
    position: "bottom-16 -left-2 sm:-left-8 md:-left-12",
    depth: 8,
    icon: <ShieldCheck className="size-4 text-success" strokeWidth={2.2} />,
    eyebrow: "Privacy",
    title: "0 telemetry",
    meta: "MIT licensed",
  },
];

export function FloatingStatCards() {
  const wrapRef = useRef<HTMLDivElement>(null);
  const reduceMotion = useReducedMotion() ?? false;

  const mx = useMotionValue(0);
  const my = useMotionValue(0);
  const smx = useSpring(mx, { stiffness: 120, damping: 20, mass: 0.4 });
  const smy = useSpring(my, { stiffness: 120, damping: 20, mass: 0.4 });

  useEffect(() => {
    if (reduceMotion) return;
    if (typeof window === "undefined") return;
    if (window.matchMedia("(pointer: coarse)").matches) return;

    const el = wrapRef.current;
    if (!el) return;

    const onMove = (e: PointerEvent) => {
      const rect = el.getBoundingClientRect();
      const nx = ((e.clientX - rect.left) / rect.width) * 2 - 1;
      const ny = ((e.clientY - rect.top) / rect.height) * 2 - 1;
      mx.set(nx);
      my.set(ny);
    };
    const onLeave = () => {
      mx.set(0);
      my.set(0);
    };

    el.addEventListener("pointermove", onMove);
    el.addEventListener("pointerleave", onLeave);
    return () => {
      el.removeEventListener("pointermove", onMove);
      el.removeEventListener("pointerleave", onLeave);
    };
  }, [mx, my, reduceMotion]);

  return (
    <motion.div
      ref={wrapRef}
      className="pointer-events-none absolute inset-0"
      variants={staggerParent(0.12, 0.4)}
      initial="hidden"
      whileInView="show"
      viewport={{ once: true, amount: 0.3 }}
    >
      {CARDS.map((card) => (
        <FloatingCard key={card.title} card={card} mx={smx} my={smy} />
      ))}
    </motion.div>
  );
}

function FloatingCard({
  card,
  mx,
  my,
}: {
  card: CardSpec;
  mx: MotionValue<number>;
  my: MotionValue<number>;
}) {
  const tx = useTransform(mx, [-1, 1], [-card.depth, card.depth]);
  const ty = useTransform(my, [-1, 1], [-card.depth * 0.6, card.depth * 0.6]);

  return (
    <motion.div
      variants={cardEntry}
      whileHover={{ y: -4, transition: springSnappy }}
      style={{ x: tx, y: ty }}
      className={`pointer-events-auto absolute ${card.position} z-10`}
    >
      <GlassCard className="flex items-center gap-3 px-4 py-3">
        <div className="flex size-8 items-center justify-center rounded-full bg-white/10 text-frost-dim">
          {card.icon}
        </div>
        <div>
          <div className="text-[10px] font-medium uppercase tracking-[0.16em] text-mute">
            {card.eyebrow}
          </div>
          <div className="text-sm font-semibold leading-tight text-frost">
            {card.title}
          </div>
          {card.meta && (
            <div className="font-mono text-[10px] text-frost-dim">{card.meta}</div>
          )}
        </div>
      </GlassCard>
    </motion.div>
  );
}
