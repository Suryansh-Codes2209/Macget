import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

/**
 * Long-form typography for the standalone content pages. Deliberately scoped
 * here rather than added to globals, so it can't fight the fumadocs styles
 * that own /docs.
 */
export function Prose({
  children,
  className,
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex flex-col gap-6 text-base leading-relaxed text-cream-dim",
        "[&_h2]:mt-10 [&_h2]:text-2xl [&_h2]:font-semibold [&_h2]:tracking-tight [&_h2]:text-cream",
        "[&_h3]:mt-6 [&_h3]:text-lg [&_h3]:font-semibold [&_h3]:tracking-tight [&_h3]:text-cream",
        "[&_a]:text-brand-honey [&_a]:underline [&_a]:underline-offset-4 hover:[&_a]:text-cream",
        "[&_strong]:font-semibold [&_strong]:text-cream",
        "[&_ul]:flex [&_ul]:flex-col [&_ul]:gap-2.5 [&_ul]:pl-5 [&_ul]:list-disc [&_li]:pl-1.5",
        "[&_ol]:flex [&_ol]:flex-col [&_ol]:gap-2.5 [&_ol]:pl-5 [&_ol]:list-decimal",
        // `data-unstyled` opts a code element out — components that own their
        // own chrome (CopyCommand) set it, so these descendant rules can't
        // half-apply on top of them.
        "[&_code:not([data-unstyled])]:rounded-md [&_code:not([data-unstyled])]:border [&_code:not([data-unstyled])]:border-line [&_code:not([data-unstyled])]:bg-abyss [&_code:not([data-unstyled])]:px-1.5 [&_code:not([data-unstyled])]:py-0.5 [&_code:not([data-unstyled])]:font-mono [&_code:not([data-unstyled])]:text-[0.85em] [&_code:not([data-unstyled])]:text-cream",
        "[&_pre]:overflow-x-auto [&_pre]:rounded-card [&_pre]:border [&_pre]:border-line [&_pre]:bg-abyss [&_pre]:p-5",
        "[&_pre_code]:border-0 [&_pre_code]:bg-transparent [&_pre_code]:p-0 [&_pre_code]:text-cream-dim",
        className,
      )}
    >
      {children}
    </div>
  );
}
