"use client";

import Image from "next/image";
import Link from "next/link";
import { useMotionValueEvent, useScroll } from "motion/react";
import { useState } from "react";
import { Menu, X } from "lucide-react";
import { GradientButton } from "@/components/ui/GradientButton";
import { siteConfig } from "@/lib/site-config";
import { cn } from "@/lib/cn";

export function Nav() {
  const { scrollY } = useScroll();
  const [scrolled, setScrolled] = useState(false);
  const [open, setOpen] = useState(false);

  useMotionValueEvent(scrollY, "change", (y) => {
    setScrolled(y > 12);
  });

  return (
    <header
      className={cn(
        "fixed inset-x-0 top-0 z-50 transition-all duration-300",
        scrolled || open
          ? "border-b border-line bg-ink/70 backdrop-blur-xl"
          : "border-b border-transparent bg-transparent",
      )}
    >
      <nav
        aria-label="Primary"
        className="mx-auto flex h-16 max-w-7xl items-center justify-between px-6 lg:px-10"
      >
        <Link
          href="/"
          className="flex items-center gap-2 rounded-md px-1 py-1 transition-opacity hover:opacity-80"
          aria-label={`${siteConfig.name} home`}
        >
          <Image
            src="/macget-icon.svg"
            alt=""
            width={32}
            height={32}
            priority
            className="size-8 rounded-lg"
          />
          <span className="text-base font-semibold tracking-tight text-cream">
            {siteConfig.name}
          </span>
        </Link>

        <div className="hidden items-center gap-1 md:flex">
          {siteConfig.nav.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="rounded-pill px-4 py-2 text-sm text-cream-dim transition-colors hover:bg-white/[0.06] hover:text-cream"
            >
              {item.label}
            </Link>
          ))}
        </div>

        <div className="flex items-center gap-2">
          <GradientButton
            href={siteConfig.downloadUrl}
            external
            size="sm"
            variant="primary"
          >
            Download
          </GradientButton>

          <button
            type="button"
            onClick={() => setOpen((v) => !v)}
            aria-expanded={open}
            aria-controls="mobile-nav"
            aria-label={open ? "Close menu" : "Open menu"}
            className="inline-flex size-9 items-center justify-center rounded-pill border border-line text-cream-dim transition-colors hover:text-cream md:hidden"
          >
            {open ? <X className="size-4" /> : <Menu className="size-4" />}
          </button>
        </div>
      </nav>

      {open && (
        <div id="mobile-nav" className="border-t border-line/60 md:hidden">
          <div className="mx-auto flex max-w-7xl flex-col px-6 py-3">
            {siteConfig.nav.map((item) => (
              <Link
                key={item.href}
                href={item.href}
                onClick={() => setOpen(false)}
                className="rounded-xl px-2 py-3 text-sm text-cream-dim transition-colors hover:bg-white/[0.06] hover:text-cream"
              >
                {item.label}
              </Link>
            ))}
          </div>
        </div>
      )}
    </header>
  );
}
