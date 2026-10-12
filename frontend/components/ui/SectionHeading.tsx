import { cn } from "@/lib/cn";
import type { ReactNode } from "react";

interface SectionHeadingProps {
  /** Rendered as the h2's id, so sections can point `aria-labelledby` at it. */
  id: string;
  title: ReactNode;
  lede?: ReactNode;
  align?: "left" | "center";
  className?: string;
}

export function SectionHeading({
  id,
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
      <h2
        id={id}
        className="text-balance text-3xl font-semibold leading-[1.08] tracking-tight text-cream sm:text-[2.75rem]"
      >
        {title}
      </h2>
      {lede && (
        <p
          className={cn(
            "mt-4 max-w-2xl text-pretty text-base leading-relaxed text-cream-dim sm:text-lg",
            align === "center" && "mx-auto",
          )}
        >
          {lede}
        </p>
      )}
    </div>
  );
}
