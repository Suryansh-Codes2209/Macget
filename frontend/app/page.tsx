import { Nav } from "@/components/nav/Nav";
import { Hero } from "@/components/hero/Hero";
import { Features } from "@/components/features/Features";
import { FirstLaunchStrip } from "@/components/install/FirstLaunchStrip";
import { HowItWorks } from "@/components/how/HowItWorks";
import { FAQ } from "@/components/faq/FAQ";
import { Footer } from "@/components/footer/Footer";
import { JsonLd } from "@/components/seo/JsonLd";
import { faqPageSchema, softwareApplicationSchema } from "@/lib/seo";

export default function HomePage() {
  return (
    <>
      <JsonLd schema={softwareApplicationSchema()} />
      <JsonLd schema={faqPageSchema()} />
      <Nav />
      <main id="top" className="relative">
        <Hero />
        <Features />
        <FirstLaunchStrip />
        <HowItWorks />
        <FAQ />
      </main>
      <Footer />
    </>
  );
}
