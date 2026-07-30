"use client";

import Link from "next/link";
import { useState } from "react";
import { writeConsent, type ConsentChoice } from "@/lib/consent";
import { useConsent } from "@/lib/use-consent";

/**
 * Analytics consent prompt.
 *
 * Shown once, only to visitors who haven't answered. Declining is a real choice
 * given the same visual weight as accepting, not a dark-pattern dead end — it
 * leaves analytics in its cookieless default, so the visit is still counted
 * anonymously and nothing on the site is gated behind the answer.
 *
 * Renders nothing during SSR and the hydration pass: `useConsent` reports
 * `unknown` until localStorage is readable, which keeps the banner from
 * flashing at someone who already declined.
 */
export function ConsentBanner() {
  const consent = useConsent();
  const [dismissed, setDismissed] = useState(false);

  if (consent !== "none" || dismissed) return null;

  function choose(choice: ConsentChoice) {
    // Hiding on our own state rather than waiting for the store keeps the click
    // feeling instant, and makes the component honest if the write throws.
    setDismissed(true);
    writeConsent(choice);
  }

  return (
    <div
      role="dialog"
      aria-modal="false"
      aria-label="Analytics preferences"
      /*
       * Bottom-*right* on desktop. Bottom-left sits squarely on the hero's
       * install command and Download button — the two things a first-time
       * visitor is here to click, and the exact audience that sees this banner.
       * The right side is the chunk artwork, which is decorative.
       */
      className="animate-rise-in fixed bottom-4 left-4 right-4 z-50 mx-auto max-w-sm rounded-card border border-line bg-surface/95 p-5 shadow-[0_20px_60px_-15px_rgba(0,0,0,0.7)] backdrop-blur-xl sm:left-auto sm:right-4 sm:mx-0"
    >
      <p className="text-sm text-cream-dim">
        MacGet counts page views to gauge whether this is worth maintaining.
        Allowing a cookie lets it tell a repeat visit from a new one — that is
        the only thing it adds.
      </p>

      <p className="mt-2 text-xs text-mute">
        Decline and you&apos;re still counted, just anonymously. Either way,
        none of this touches the app or your downloads.{" "}
        <Link
          href="/privacy"
          className="text-brand-amber underline underline-offset-4 hover:text-brand-honey"
        >
          Details
        </Link>
        .
      </p>

      <div className="mt-4 flex gap-2">
        <button
          type="button"
          onClick={() => choose("granted")}
          className="flex-1 rounded-pill bg-cream px-4 py-2 text-sm font-medium text-brand-umber transition-colors hover:bg-white"
        >
          Allow
        </button>
        <button
          type="button"
          onClick={() => choose("denied")}
          className="flex-1 rounded-pill border border-line bg-white/[0.04] px-4 py-2 text-sm font-medium text-cream transition-colors hover:border-white/20 hover:bg-white/[0.08]"
        >
          Decline
        </button>
      </div>
    </div>
  );
}
