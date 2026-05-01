"use client";

import { motion, type Variants } from "motion/react";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";
import { staggerParent, fadeUp } from "@/lib/motion";

interface MotionInViewProps {
  children: ReactNode;
  className?: string;
  stagger?: number;
  delay?: number;
  amount?: number;
  as?: "div" | "section" | "ul";
}

export function MotionInView({
  children,
  className,
  stagger = 0.08,
  delay = 0,
  amount = 0.3,
  as = "div",
}: MotionInViewProps) {
  const Tag = motion[as];
  return (
    <Tag
      className={cn(className)}
      variants={staggerParent(stagger, delay)}
      initial="hidden"
      whileInView="show"
      viewport={{ once: true, amount }}
    >
      {children}
    </Tag>
  );
}

interface MotionItemProps {
  children: ReactNode;
  className?: string;
  variants?: Variants;
}

export function MotionItem({
  children,
  className,
  variants = fadeUp,
}: MotionItemProps) {
  return (
    <motion.div className={className} variants={variants}>
      {children}
    </motion.div>
  );
}
