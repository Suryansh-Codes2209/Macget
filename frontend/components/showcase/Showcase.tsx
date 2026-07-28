import Image from "next/image";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { MotionInView, MotionItem } from "@/components/ui/MotionInView";

/**
 * Screenshots of the running app.
 *
 * Deliberately unretouched captures rather than mockups — the numbers in the
 * annotations below are read off the shots, so the section stays honest as long
 * as the images are replaced together with the copy.
 */

interface Annotation {
  label: string;
  value: string;
  blurb: string;
}

const ANNOTATIONS: Annotation[] = [
  {
    label: "Speed",
    value: "30-second window",
    blurb:
      "Throughput sampled at the engine's 250 ms cadence and drawn as a continuously scrolling curve, with the window's peak and average alongside. It slides between samples, so it reads as live rather than polled.",
  },
  {
    label: "Pieces",
    value: "256 × 21.2 MB",
    blurb:
      "The file drawn as its real work units, in file order. Filled cells are done, outlined ones are in a worker's hands right now. Work-stealing is visible here and nowhere else — a single bar hides it completely.",
  },
  {
    label: "Connections",
    value: "8 requested → 6 effective",
    blurb:
      "Every distinct reason the worker count can sit below what you asked for, each on its own line: a cap learned from this host, a demotion after it started refusing connections, or simply your own setting. A download opens at its full count immediately — the number only comes down on evidence.",
  },
];

export function Showcase() {
  return (
    <section
      id="inspector"
      aria-labelledby="inspector-heading"
      className="relative py-28 sm:py-36"
    >
      {/* Warm bloom behind the figure, matching the hero treatment. */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[520px] bg-radial-glow"
      />

      <div className="mx-auto max-w-7xl px-6 lg:px-10">
        <SectionHeading
          eyebrow="The inspector"
          title={
            <span id="inspector-heading">
              Not a progress bar.
              <br className="hidden sm:inline" /> A readout.
            </span>
          }
          lede="One bar creeping right looks the same over 1 connection or 16. MacGet shows you the throughput curve, the actual pieces in flight, and exactly why the engine settled on the concurrency it did."
        />

        <MotionInView className="mt-16 grid items-start gap-6 lg:grid-cols-12">
          <MotionItem className="lg:col-span-8">
            <figure className="overflow-hidden rounded-card border border-line bg-surface/60 shadow-[0_40px_120px_-40px_rgba(0,0,0,0.9)]">
              <Image
                src="/screenshots/macget-inspector.png"
                alt="The MacGet window with a download selected and the inspector open, showing a live speed chart, the file's piece map, and the connection breakdown."
                width={1439}
                height={920}
                className="h-auto w-full"
                sizes="(min-width: 1024px) 66vw, 100vw"
                priority={false}
              />
            </figure>
            <figcaption className="mt-3 text-sm text-mute">
              A 5.43 GB transfer mid-flight, split into 256 pieces across 6
              connections.
            </figcaption>
          </MotionItem>

          {/* The panel at native scale — in the full-window shot above it is too
              small to actually read, which defeats the point of showing it. */}
          <MotionItem className="lg:col-span-4">
            <figure className="overflow-hidden rounded-card border border-line bg-surface/60 shadow-[0_40px_120px_-40px_rgba(0,0,0,0.9)]">
              <Image
                src="/screenshots/macget-inspector-panel.png"
                alt="The inspector panel at full size: current speed with peak and average, the piece map with done, in-flight and pending counts, transfer totals, and the connection breakdown."
                width={297}
                height={816}
                className="h-auto w-full"
                sizes="(min-width: 1024px) 33vw, 100vw"
              />
            </figure>
            <figcaption className="mt-3 text-sm text-mute">
              The panel at native scale.
            </figcaption>
          </MotionItem>
        </MotionInView>

        <MotionInView className="mt-14 grid gap-5 sm:grid-cols-3">
          {ANNOTATIONS.map((a) => (
            <MotionItem
              key={a.label}
              className="rounded-card border border-line bg-white/[0.03] p-6"
            >
              <div className="text-xs font-medium uppercase tracking-[0.18em] text-brand-honey">
                {a.label}
              </div>
              <div className="mt-2 font-mono text-lg font-semibold tracking-tight text-cream">
                {a.value}
              </div>
              <p className="mt-3 text-sm leading-relaxed text-cream-dim">
                {a.blurb}
              </p>
            </MotionItem>
          ))}
        </MotionInView>

        <MotionInView className="mt-20">
          <MotionItem>
            <figure className="overflow-hidden rounded-card border border-line bg-surface/60 shadow-[0_40px_120px_-40px_rgba(0,0,0,0.9)]">
              <Image
                src="/screenshots/macget-queue.png"
                alt="The MacGet download list showing completed, failed and in-progress downloads, with aggregate throughput in the side panel."
                width={1439}
                height={920}
                className="h-auto w-full"
                sizes="100vw"
              />
            </figure>
            <figcaption className="mt-3 text-sm text-mute">
              The queue itself — filterable by state, with aggregate throughput
              when nothing is selected.
            </figcaption>
          </MotionItem>
        </MotionInView>
      </div>
    </section>
  );
}
