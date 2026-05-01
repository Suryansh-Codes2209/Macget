"use client";

import { AnimatePresence, motion } from "motion/react";
import { ChevronDown } from "lucide-react";
import { useState, useId } from "react";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { siteConfig } from "@/lib/site-config";
import { cn } from "@/lib/cn";

export function FAQ() {
  const [openIndex, setOpenIndex] = useState<number | null>(0);

  return (
    <section
      id="faq"
      aria-labelledby="faq-heading"
      className="relative py-28 sm:py-36"
    >
      <div className="mx-auto max-w-3xl px-6 lg:px-10">
        <SectionHeading
          align="center"
          eyebrow="FAQ"
          title={<span id="faq-heading">Quick answers.</span>}
          lede="If something here is unclear, the README and source code are the source of truth."
        />

        <ul className="mt-14 space-y-2">
          {siteConfig.faq.map((item, i) => (
            <FAQItem
              key={item.q}
              question={item.q}
              answer={item.a}
              isOpen={openIndex === i}
              onToggle={() => setOpenIndex(openIndex === i ? null : i)}
            />
          ))}
        </ul>
      </div>
    </section>
  );
}

interface FAQItemProps {
  question: string;
  answer: string;
  isOpen: boolean;
  onToggle: () => void;
}

function FAQItem({ question, answer, isOpen, onToggle }: FAQItemProps) {
  const id = useId();
  return (
    <li className="overflow-hidden rounded-card border border-line bg-surface/40 transition-colors hover:border-white/15">
      <button
        type="button"
        onClick={onToggle}
        aria-expanded={isOpen}
        aria-controls={id}
        className="flex w-full items-center justify-between gap-6 px-6 py-5 text-left"
      >
        <span className="text-base font-medium text-frost sm:text-lg">
          {question}
        </span>
        <ChevronDown
          className={cn(
            "size-5 shrink-0 text-frost-dim transition-transform duration-300",
            isOpen && "rotate-180 text-brand-sky",
          )}
          strokeWidth={2.2}
        />
      </button>
      <AnimatePresence initial={false}>
        {isOpen && (
          <motion.div
            id={id}
            key="content"
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: "auto", opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={{ duration: 0.3, ease: [0.2, 0.8, 0.2, 1] }}
            className="overflow-hidden"
          >
            <div className="px-6 pb-6 text-sm leading-relaxed text-frost-dim sm:text-base">
              {answer}
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </li>
  );
}
