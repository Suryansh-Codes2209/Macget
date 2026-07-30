"use client";

import { writeConsent, type ConsentChoice } from "@/lib/consent";
import { useConsent } from "@/lib/use-consent";

/**
 * The withdrawal half of the consent flow, for the privacy page.
 *
 * Consent that can only be given and never taken back isn't consent, so this
 * has to be at least as reachable as the banner that asked. It reports the
 * current state — including "hasn't chosen", which is a real third state and
 * not the same as declining — and flips it in one click.
 */
export function AnalyticsPreferences() {
  const consent = useConsent();

  const status =
    consent === "granted"
      ? "Analytics cookies are allowed on this browser."
      : consent === "denied"
        ? "Analytics cookies are off. Visits are still counted anonymously."
        : "You haven't chosen yet, so analytics is running without cookies.";

  function set(next: ConsentChoice) {
    writeConsent(next);
  }

  return (
    <div className="not-prose my-6 rounded-card border border-line bg-surface p-5">
      {/*
        `unknown` (SSR and the hydration pass) renders the same frame with the
        text hidden rather than a different layout, so the box doesn't resize
        under the reader when the real state arrives.
      */}
      <p
        className="text-sm text-cream-dim"
        style={{ visibility: consent === "unknown" ? "hidden" : undefined }}
      >
        {consent === "unknown" ? " " : status}
      </p>
      <div className="mt-4 flex flex-wrap gap-2">
        <button
          type="button"
          onClick={() => set("granted")}
          disabled={consent === "granted" || consent === "unknown"}
          className="rounded-pill bg-cream px-4 py-2 text-sm font-medium text-brand-umber transition-colors hover:bg-white disabled:cursor-default disabled:opacity-40 disabled:hover:bg-cream"
        >
          Allow analytics cookies
        </button>
        <button
          type="button"
          onClick={() => set("denied")}
          disabled={consent === "denied" || consent === "unknown"}
          className="rounded-pill border border-line bg-white/[0.04] px-4 py-2 text-sm font-medium text-cream transition-colors hover:border-white/20 hover:bg-white/[0.08] disabled:cursor-default disabled:opacity-40 disabled:hover:border-line disabled:hover:bg-white/[0.04]"
        >
          Turn them off
        </button>
      </div>
    </div>
  );
}
