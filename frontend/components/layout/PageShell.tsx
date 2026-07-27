import type { ReactNode } from "react";
import { Nav } from "@/components/nav/Nav";
import { Footer } from "@/components/footer/Footer";

interface PageShellProps {
  eyebrow?: string;
  title: string;
  lede?: ReactNode;
  meta?: ReactNode;
  children: ReactNode;
}

/** Shared frame for the standalone content pages (install, privacy, changelog). */
export function PageShell({
  eyebrow,
  title,
  lede,
  meta,
  children,
}: PageShellProps) {
  return (
    <>
      <Nav />
      <main className="relative">
        <div className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[420px] bg-radial-glow" />

        <header className="mx-auto max-w-3xl px-6 pt-36 pb-10 lg:px-10">
          {eyebrow && (
            <div className="mb-4 inline-flex items-center gap-2 rounded-pill border border-line bg-white/[0.04] px-3 py-1 text-xs font-medium uppercase tracking-[0.18em] text-frost-dim">
              <span className="size-1.5 rounded-full bg-brand-sky" />
              {eyebrow}
            </div>
          )}
          <h1 className="text-balance text-4xl font-semibold leading-[1.05] tracking-tight text-frost sm:text-5xl">
            {title}
          </h1>
          {lede && (
            <p className="mt-5 text-base leading-relaxed text-frost-dim sm:text-lg">
              {lede}
            </p>
          )}
          {meta && <div className="mt-6 text-sm text-mute">{meta}</div>}
        </header>

        <div className="mx-auto max-w-3xl px-6 pb-28 lg:px-10">{children}</div>
      </main>
      <Footer />
    </>
  );
}
