import type { Variants, Transition } from "motion/react";

export const easeEmphasized: [number, number, number, number] = [0.2, 0.8, 0.2, 1];
export const easeEmphasizedDecel: [number, number, number, number] = [0.05, 0.7, 0.1, 1];

export const springSoft: Transition = {
  type: "spring",
  stiffness: 120,
  damping: 20,
  mass: 0.4,
};

export const springSnappy: Transition = {
  type: "spring",
  stiffness: 300,
  damping: 20,
};

export const fadeUp: Variants = {
  hidden: { opacity: 0, y: 24 },
  show: {
    opacity: 1,
    y: 0,
    transition: { duration: 0.7, ease: easeEmphasized },
  },
};

export const cardEntry: Variants = {
  hidden: { opacity: 0, y: 24, scale: 0.96 },
  show: {
    opacity: 1,
    y: 0,
    scale: 1,
    transition: { duration: 0.7, ease: easeEmphasized },
  },
};

export const staggerParent = (stagger = 0.08, delay = 0): Variants => ({
  hidden: {},
  show: {
    transition: {
      staggerChildren: stagger,
      delayChildren: delay,
    },
  },
});
