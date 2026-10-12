import { Check } from "lucide-react";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { siteConfig } from "@/lib/site-config";
import { cn } from "@/lib/cn";

/**
 * The three engine behaviours, each as a row: claim + specifics on one side,
 * a small static diagram of the same idea on the other. The diagrams are drawn
 * in the app's own vocabulary (piece cells, progress gradient) so the site and
 * the app show the same thing.
 */
export function Features() {
  return (
    <section
      id="features"
      aria-labelledby="features-heading"
      className="relative scroll-mt-16 py-20 sm:py-28"
    >
      <div className="mx-auto max-w-6xl px-6 lg:px-10">
        <SectionHeading
          id="features-heading"
          title="What happens when you add a download"
          lede="Three things MacGet does that a browser's single progress bar doesn't."
        />

        <div className="mt-14 divide-y divide-line border-y border-line">
          {siteConfig.engine.map((item) => (
            <article
              key={item.id}
              className="grid gap-8 py-12 md:grid-cols-[1.1fr_1fr] md:items-center md:gap-14 sm:py-14"
            >
              <div>
                <h3 className="text-2xl font-semibold tracking-tight text-cream">
                  {item.title}
                </h3>
                <p className="mt-3 text-pretty leading-relaxed text-cream-dim">
                  {item.summary}
                </p>
                <ul className="mt-6 space-y-3">
                  {item.points.map((point) => (
                    <li
                      key={point}
                      className="flex gap-3 text-sm leading-relaxed text-cream-dim"
                    >
                      <Check
                        className="mt-0.5 size-4 shrink-0 text-brand-honey"
                        strokeWidth={2.4}
                      />
                      {point}
                    </li>
                  ))}
                </ul>
              </div>
              <div className="rounded-tile border border-line bg-surface/60 p-6 sm:p-8">
                {item.id === "parallel" && <ParallelDiagram />}
                {item.id === "adaptive" && <AdaptiveDiagram />}
                {item.id === "resume" && <ResumeDiagram />}
              </div>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

/* ---------- diagrams ---------- */

// 0 = done, 1 = in a worker's hands, 2 = waiting. Done cells cluster at the
// front but not perfectly: workers finish out of order.
const PIECES = [
  0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1,
  0, 0, 1, 2, 1, 0, 1, 2, 2, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
];

function ParallelDiagram() {
  const done = PIECES.filter((p) => p === 0).length;
  const active = PIECES.filter((p) => p === 1).length;
  return (
    <div>
      <div className="flex items-baseline justify-between text-sm">
        <span className="truncate text-cream">ubuntu-24.04-desktop-amd64.iso</span>
        <span className="shrink-0 pl-3 tabular-nums text-mute">5.8 GB</span>
      </div>
      <div
        className="mt-5 grid grid-cols-12 gap-1.5"
        role="img"
        aria-label={`${PIECES.length} pieces: ${done} done, ${active} downloading, the rest waiting`}
      >
        {PIECES.map((p, i) => (
          <span
            key={i}
            className={cn(
              "aspect-square rounded-[4px]",
              p === 0 && "bg-progress-gradient",
              p === 1 && "animate-pulse border border-brand-honey bg-brand-honey/20",
              p === 2 && "bg-white/[0.06]",
            )}
          />
        ))}
      </div>
      <div className="mt-5 flex flex-wrap gap-x-5 gap-y-2 text-xs text-mute">
        <Legend className="bg-progress-gradient">Done</Legend>
        <Legend className="border border-brand-honey bg-brand-honey/20">
          Downloading now
        </Legend>
        <Legend className="bg-white/[0.06]">Waiting for a free worker</Legend>
      </div>
    </div>
  );
}

function AdaptiveDiagram() {
  const rows = [
    { label: "Opens at", value: 16, note: "your setting", tone: "full" },
    { label: "Host refuses some", value: 8, note: "halved", tone: "half" },
    { label: "Next visit", value: 8, note: "remembered for 7 days", tone: "half" },
  ] as const;
  return (
    <ul className="space-y-6">
      {rows.map((row) => (
        <li key={row.label}>
          <div className="flex items-baseline justify-between gap-4 text-sm">
            <span className="text-cream">{row.label}</span>
            <span className="text-mute">
              <span className="font-semibold tabular-nums text-cream">
                {row.value}
              </span>{" "}
              connections, {row.note}
            </span>
          </div>
          <div className="mt-2.5 grid grid-cols-16 gap-1">
            {Array.from({ length: 16 }, (_, i) => (
              <span
                key={i}
                className={cn(
                  "h-5 rounded-[3px]",
                  i < row.value ? "bg-progress-gradient" : "bg-white/[0.06]",
                )}
              />
            ))}
          </div>
        </li>
      ))}
    </ul>
  );
}

function ResumeDiagram() {
  const steps = [
    { label: "Downloading", pct: 62, note: "3.6 of 5.8 GB" },
    { label: "Mac restarts", pct: 62, note: "progress saved per piece", paused: true },
    { label: "Back on", pct: 63, note: "resumed at 62%, file unchanged" },
  ];
  return (
    <ol className="space-y-6">
      {steps.map((step) => (
        <li key={step.label}>
          <div className="flex items-baseline justify-between gap-4 text-sm">
            <span className="text-cream">{step.label}</span>
            <span className="text-right text-mute">{step.note}</span>
          </div>
          <div className="mt-2.5 h-2 overflow-hidden rounded-pill bg-white/[0.06]">
            <div
              className={cn(
                "h-full rounded-pill",
                step.paused ? "bg-cream-dim/40" : "bg-progress-gradient",
              )}
              style={{ width: `${step.pct}%` }}
            />
          </div>
        </li>
      ))}
    </ol>
  );
}

function Legend({
  className,
  children,
}: {
  className: string;
  children: React.ReactNode;
}) {
  return (
    <span className="inline-flex items-center gap-2">
      <span className={cn("size-2.5 rounded-[3px]", className)} />
      {children}
    </span>
  );
}
