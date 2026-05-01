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
          lede="One shared URLSession. Six features that compound. No background daemons, no kernel extensions, no telemetry."
        />

        <MotionInView className="mt-16 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
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
