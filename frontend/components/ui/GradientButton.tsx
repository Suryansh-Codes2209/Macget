import { cn } from "@/lib/cn";
import type { AnchorHTMLAttributes, ReactNode } from "react";

interface GradientButtonProps extends AnchorHTMLAttributes<HTMLAnchorElement> {
  children: ReactNode;
  variant?: "primary" | "ghost";
  size?: "sm" | "md" | "lg";
  className?: string;
  external?: boolean;
}

export function GradientButton({
  children,
  variant = "primary",
  size = "md",
  className,
  external,
  href,
  ...rest
}: GradientButtonProps) {
  const sizeClasses = {
    sm: "px-4 py-2 text-sm",
    md: "px-5 py-2.5 text-sm",
    lg: "px-7 py-3.5 text-base",
  } as const;

  const base =
    "group relative inline-flex items-center justify-center gap-2 rounded-pill font-medium tracking-tight transition-all duration-200 will-change-transform";

  const variantClasses =
    variant === "primary"
      ? "bg-cream text-brand-umber hover:bg-white hover:-translate-y-0.5 hover:shadow-[0_12px_40px_-8px_rgba(247,196,94,0.6)] active:translate-y-0"
      : "border border-line bg-white/[0.04] text-cream hover:bg-white/[0.08] hover:border-white/20";

  return (
    <a
      href={href}
      className={cn(base, sizeClasses[size], variantClasses, className)}
      {...(external
        ? { target: "_blank", rel: "noreferrer noopener" }
        : {})}
      {...rest}
    >
      {children}
    </a>
  );
}
