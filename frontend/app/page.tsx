import { Nav } from "@/components/nav/Nav";
import { Hero } from "@/components/hero/Hero";
import { Features } from "@/components/features/Features";
import { HowItWorks } from "@/components/how/HowItWorks";
import { FAQ } from "@/components/faq/FAQ";
import { Footer } from "@/components/footer/Footer";

export default function HomePage() {
  return (
    <>
      <Nav />
      <main id="top" className="relative">
        <Hero />
        <Features />
        <HowItWorks />
        <FAQ />
      </main>
      <Footer />
    </>
  );
}
