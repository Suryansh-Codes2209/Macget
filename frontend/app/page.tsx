import { Nav } from "@/components/nav/Nav";
import { Hero } from "@/components/hero/Hero";
import { Features } from "@/components/features/Features";
import { More } from "@/components/features/More";
import { Bonding } from "@/components/bonding/Bonding";
import { Showcase } from "@/components/showcase/Showcase";
import { HowItWorks } from "@/components/how/HowItWorks";
import { InstallSection } from "@/components/install/InstallSection";
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
        <Showcase />
        <Bonding />
        <More />
        <HowItWorks />
        <InstallSection />
        <FAQ />
      </main>
      <Footer />
    </>
  );
}
