import { SectionHeading } from "@/components/ui/SectionHeading";
import { siteConfig } from "@/lib/site-config";

const ARCHITECTURE_URL = `${siteConfig.repoUrl}/blob/main/docs/architecture.md`;

/** A real sequence — every download walks these four stages in order. */
export function HowItWorks() {
  return (
    <section
      id="how"
      aria-labelledby="how-heading"
      className="relative scroll-mt-16 py-20 sm:py-28"
    >
      <div className="mx-auto max-w-6xl px-6 lg:px-10">
        <SectionHeading
          id="how-heading"
          title="Under the hood, in four steps"
          lede={
            <>
              Every download takes the same path. The{" "}
              <a
                href={ARCHITECTURE_URL}
                target="_blank"
                rel="noreferrer noopener"
                className="text-cream underline decoration-line underline-offset-4 hover:decoration-cream/40"
              >
                architecture notes
              </a>{" "}
              go deeper.
            </>
          }
        />

        <ol className="relative mt-14 grid gap-8 sm:grid-cols-2 lg:grid-cols-4 lg:gap-6">
          {/* Connecting rule behind the step markers, desktop only. */}
          <div
            aria-hidden
            className="absolute left-4 right-4 top-4 hidden h-px bg-gradient-to-r from-brand-honey/60 via-brand-amber/40 to-transparent lg:block"
          />
          {siteConfig.pipeline.map((step, i) => (
            <li key={step.step} className="relative">
              <span className="relative z-10 flex size-8 items-center justify-center rounded-full border border-brand-amber/50 bg-ink text-sm font-semibold tabular-nums text-brand-honey">
                {i + 1}
              </span>
              <h3 className="mt-5 font-semibold tracking-tight text-cream">
                {step.step}
              </h3>
              <p className="mt-1.5 text-sm leading-relaxed text-cream-dim">
                {step.detail}
              </p>
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}
