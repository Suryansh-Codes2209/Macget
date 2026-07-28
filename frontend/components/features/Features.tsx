import { SectionHeading } from "@/components/ui/SectionHeading";
import { MotionInView } from "@/components/ui/MotionInView";
import { FeatureCard } from "./FeatureCard";
import { siteConfig } from "@/lib/site-config";

export function Features() {
  return (
    <section
      id="features"
      aria-labelledby="features-heading"
      className="relative py-28 sm:py-36"
    >
      <div className="mx-auto max-w-7xl px-6 lg:px-10">
        <SectionHeading
          eyebrow="Why MacGet"
          title={
            <span id="features-heading">
              Built around how downloads
              <br className="hidden sm:inline" /> actually work.
            </span>
          }
          lede="One shared URLSession, an engine that learns each host's limits, and no background daemons, kernel extensions, or telemetry anywhere."
        />

        {/* One column on a phone makes this grid several viewports tall, so the
            default 30%-visible trigger never fires and every card stays at its
            hidden opacity — the section renders blank. */}
        <MotionInView
          amount={0.05}
          className="mt-16 grid gap-5 sm:grid-cols-2 lg:grid-cols-3"
        >
          {siteConfig.features.map((feature) => (
            <FeatureCard
              key={feature.title}
              title={feature.title}
              blurb={feature.blurb}
              iconName={feature.icon}
            />
          ))}
        </MotionInView>
      </div>
    </section>
  );
}
