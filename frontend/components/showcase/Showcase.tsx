import Image from "next/image";
import { SectionHeading } from "@/components/ui/SectionHeading";

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
    value: "Last 30 seconds",
    blurb:
      "A live throughput curve with the peak and average beside it, updated four times a second.",
  },
  {
    label: "Pieces",
    value: "256 × 21.2 MB",
    blurb:
      "The file as its real pieces, in order. Filled cells are done; outlined ones are downloading right now.",
  },
  {
    label: "Connections",
    value: "8 requested → 6 effective",
    blurb:
      "If MacGet is using fewer connections than you asked for, it says why: your setting, a limit learned from this host, or a host that started refusing.",
  },
];

export function Showcase() {
  return (
    <section
      id="inspector"
      aria-labelledby="inspector-heading"
      className="relative scroll-mt-16 py-20 sm:py-28"
    >
      {/* Warm bloom behind the figure, matching the hero treatment. */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[520px] bg-radial-glow"
      />

      <div className="mx-auto max-w-6xl px-6 lg:px-10">
        <SectionHeading
          id="inspector-heading"
          title="See exactly what each download is doing"
          lede="Select a download to open the inspector: speed over time, every piece of the file, and how many connections are working on it."
        />

        <div className="mt-14 grid items-start gap-6 lg:grid-cols-12">
          <div className="lg:col-span-8">
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
          </div>

          {/* The panel at native scale — in the full-window shot above it is too
              small to actually read, which defeats the point of showing it. */}
          <div className="lg:col-span-4">
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
          </div>
        </div>

        <dl className="mt-12 grid gap-8 border-t border-line pt-10 sm:grid-cols-3">
          {ANNOTATIONS.map((a) => (
            <div key={a.label}>
              <dt className="text-sm text-mute">{a.label}</dt>
              <dd className="mt-1 text-lg font-semibold tracking-tight text-cream">
                {a.value}
              </dd>
              <dd className="mt-2 text-sm leading-relaxed text-cream-dim">
                {a.blurb}
              </dd>
            </div>
          ))}
        </dl>

        <div className="mt-16">
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
        </div>
      </div>
    </section>
  );
}
