import { cn } from "@/lib/cn";
import type { ReactNode } from "react";

interface SectionHeadingProps {
  eyebrow?: string;
  title: ReactNode;
  lede?: ReactNode;
  align?: "left" | "center";
  className?: string;
}

export function SectionHeading({
  eyebrow,
  title,
  lede,
  align = "left",
  className,
}: SectionHeadingProps) {
  return (
    <div
      className={cn(
        "max-w-3xl",
        align === "center" && "mx-auto text-center",
        className,
      )}
    >
      {eyebrow && (
        <div className="mb-4 inline-flex items-center gap-2 rounded-pill border border-line bg-white/[0.04] px-3 py-1 text-xs font-medium uppercase tracking-[0.18em] text-cream-dim">
          <span className="size-1.5 rounded-full bg-brand-honey" />
          {eyebrow}
        </div>
      )}
      <h2 className="text-balance text-4xl font-semibold leading-[1.05] tracking-tight text-cream sm:text-5xl">
        {title}
      </h2>
      {lede && (
        <p className="mt-5 max-w-2xl text-base leading-relaxed text-cream-dim sm:text-lg">
          {lede}
        </p>
      )}
    </div>
  );
}
