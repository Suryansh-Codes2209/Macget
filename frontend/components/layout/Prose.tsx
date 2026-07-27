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
        "flex flex-col gap-6 text-base leading-relaxed text-frost-dim",
        "[&_h2]:mt-10 [&_h2]:text-2xl [&_h2]:font-semibold [&_h2]:tracking-tight [&_h2]:text-frost",
        "[&_h3]:mt-6 [&_h3]:text-lg [&_h3]:font-semibold [&_h3]:tracking-tight [&_h3]:text-frost",
        "[&_a]:text-brand-sky [&_a]:underline [&_a]:underline-offset-4 hover:[&_a]:text-frost",
        "[&_strong]:font-semibold [&_strong]:text-frost",
        "[&_ul]:flex [&_ul]:flex-col [&_ul]:gap-2.5 [&_ul]:pl-5 [&_ul]:list-disc [&_li]:pl-1.5",
        "[&_ol]:flex [&_ol]:flex-col [&_ol]:gap-2.5 [&_ol]:pl-5 [&_ol]:list-decimal",
        "[&_code]:rounded-md [&_code]:border [&_code]:border-line [&_code]:bg-abyss [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:font-mono [&_code]:text-[0.85em] [&_code]:text-frost",
        "[&_pre]:overflow-x-auto [&_pre]:rounded-card [&_pre]:border [&_pre]:border-line [&_pre]:bg-abyss [&_pre]:p-5",
        "[&_pre_code]:border-0 [&_pre_code]:bg-transparent [&_pre_code]:p-0 [&_pre_code]:text-frost-dim",
        className,
      )}
    >
      {children}
    </div>
  );
}
