import { Laptop, Smartphone, Wifi, Cable } from "lucide-react";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { siteConfig } from "@/lib/site-config";
import { cn } from "@/lib/cn";

const PIECES = 48;

// Color each link the way the file grid paints its pieces. The phone is
// deliberately not `seeding` blue — that token means bytes going *out*.
const LINK_STYLES = [
  { swatch: "bg-brand-honey", bar: "from-brand-honey to-brand-amber", Icon: Wifi },
  { swatch: "bg-cream-dim/70", bar: "from-cream-dim/80 to-cream-dim/40", Icon: Smartphone },
];

/**
 * Which link delivered each piece. Spread evenly by share rather than in two
 * solid blocks, because that's what work stealing actually produces: both
 * links pull the next outstanding piece, so their pieces interleave through
 * the file and the faster link simply ends up with more of them.
 */
function pieceOwners(share: number): number[] {
  return Array.from({ length: PIECES }, (_, i) =>
    Math.floor((i + 1) * share) > Math.floor(i * share) ? 0 : 1,
  );
}

export function Bonding() {
  const { links, devices, facts } = siteConfig.bonding;
  const owners = pieceOwners(links[0].share);

  return (
    <section
      id="bonding"
      aria-labelledby="bonding-heading"
      className="relative scroll-mt-16 py-20 sm:py-28"
    >
      <div className="mx-auto max-w-6xl px-6 lg:px-10">
        <SectionHeading
          id="bonding-heading"
          title="Use Wi-Fi and your phone at the same time"
          lede="Plug in a phone or a second network and MacGet can download one file over both — different pieces down each link, joined back into one file."
        />

        <div className="mt-14 grid items-start gap-6 lg:grid-cols-12">
          <div className="lg:col-span-7">
            <div className="rounded-tile border border-line bg-surface/60 p-7 sm:p-9">
              <div className="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
                <h3 className="text-lg font-semibold tracking-tight text-cream">
                  One file, two paths
                </h3>
                <span className="text-xs text-mute">Example</span>
              </div>

              <ul className="mt-7 space-y-4" aria-label="Bonded links">
                {links.map((link, i) => {
                  const { Icon, bar } = LINK_STYLES[i];
                  return (
                    <li key={link.name} className="flex items-center gap-4">
                      <span className="inline-flex size-10 shrink-0 items-center justify-center rounded-2xl border border-line bg-white/[0.04] text-cream">
                        <Icon className="size-4" />
                      </span>
                      <div className="min-w-0 flex-1">
                        <div className="flex items-baseline justify-between gap-3 text-sm">
                          <span className="font-medium text-cream">{link.name}</span>
                          <span className="shrink-0 font-mono text-xs text-mute">
                            <span className="hidden sm:inline">{link.kind} · </span>
                            {Math.round(link.share * 100)}% of pieces
                          </span>
                        </div>
                        <div className="mt-2 h-1.5 overflow-hidden rounded-pill bg-white/[0.06]">
                          <div
                            className={cn("h-full rounded-pill bg-gradient-to-r", bar)}
                            style={{ width: `${link.share * 100}%` }}
                          />
                        </div>
                      </div>
                    </li>
                  );
                })}
              </ul>

              <div className="mt-8 border-t border-line pt-7">
                <div className="flex items-center gap-2 text-sm text-cream-dim">
                  <Laptop className="size-4 text-brand-honey" />
                  <span>ubuntu-24.04-desktop-amd64.iso</span>
                </div>
                <div className="mt-4 grid grid-cols-12 gap-1.5 sm:grid-cols-16">
                  {owners.map((owner, i) => (
                    <span
                      key={i}
                      className={cn(
                        "aspect-square rounded-[4px]",
                        LINK_STYLES[owner].swatch,
                      )}
                    >
                      <span className="sr-only">
                        Piece {i + 1} via {links[owner].name}
                      </span>
                    </span>
                  ))}
                </div>
                <div className="mt-4 flex flex-wrap gap-x-5 gap-y-2 text-xs text-mute">
                  {links.map((link, i) => (
                    <span key={link.name} className="inline-flex items-center gap-2">
                      <span className={cn("size-2.5 rounded-[3px]", LINK_STYLES[i].swatch)} />
                      via {link.name}
                    </span>
                  ))}
                </div>
              </div>

              <div className="mt-8 border-t border-line pt-6">
                <div className="flex items-center gap-2 text-sm font-medium text-cream">
                  <Cable className="size-4 text-brand-honey" />
                  Works with any link your Mac can see
                </div>
                <ul className="mt-4 flex flex-wrap gap-2" aria-label="Supported links">
                  {devices.map((device) => (
                    <li
                      key={device}
                      className="rounded-pill border border-line px-3 py-1 text-xs text-mute"
                    >
                      {device}
                    </li>
                  ))}
                </ul>
              </div>
            </div>
          </div>

          <ul className="flex flex-col divide-y divide-line lg:col-span-5">
            {facts.map((fact) => (
              <li key={fact.title} className="py-6 first:pt-2 last:pb-0">
                <h3 className="text-lg font-semibold tracking-tight text-cream">
                  {fact.title}
                </h3>
                <p className="mt-2 text-sm leading-relaxed text-cream-dim">
                  {fact.detail}
                </p>
              </li>
            ))}
          </ul>
        </div>
      </div>
    </section>
  );
}
