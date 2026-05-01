import { cn } from "@/lib/cn";
import type { HTMLAttributes, ReactNode } from "react";

interface GlassCardProps extends HTMLAttributes<HTMLDivElement> {
  children: ReactNode;
  className?: string;
}

export function GlassCard({ children, className, ...rest }: GlassCardProps) {
  return (
    <div
      className={cn(
        "relative rounded-card border border-line bg-white/[0.06] backdrop-blur-xl",
        "shadow-[inset_0_1px_0_rgba(255,255,255,0.08),0_8px_32px_rgba(0,8,32,0.4)]",
        "transition-colors hover:border-white/20",
        className,
      )}
      {...rest}
    >
      {children}
    </div>
  );
}
