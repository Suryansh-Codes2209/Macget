/**
 * Analytics consent, stored client-side only.
 *
 * The stored value is the *whole* record — there is no server call and no
 * consent-management vendor. Writing a consent record is itself exempt from the
 * consent requirement it records (it is strictly necessary to honour the
 * choice), which is why this can use localStorage without waiting on itself.
 *
 * This file imports nothing from React on purpose. `Analytics` is a server
 * component and needs the real value of `CONSENT_STORAGE_KEY` to inline into
 * its bootstrap script — but a module that so much as imports a hook cannot be
 * pulled into a server component at all, and marking this `"use client"` would
 * hand that server component a client-reference proxy instead of the string.
 * The `useConsent` hook therefore lives next door in `use-consent.ts`.
 *
 * The state is modelled as an external store rather than component state so the
 * banner, the privacy page's preferences panel, and any other open tab all read
 * one source of truth.
 */

export const CONSENT_STORAGE_KEY = "macget-analytics-consent";

/** Same-tab change notification. The `storage` event only fires cross-tab. */
const CONSENT_EVENT = "macget:consent-change";

export type ConsentChoice = "granted" | "denied";

/**
 * `none` — visitor hasn't answered; analytics runs cookieless and we ask.
 * `unknown` — server render and the hydration pass, where localStorage doesn't
 * exist yet. Distinct from `none` so nothing flashes a banner at someone who
 * already declined.
 */
export type ConsentState = ConsentChoice | "none" | "unknown";

let cached: ConsentChoice | "none" | null = null;

function read(): ConsentChoice | "none" {
  try {
    const value = window.localStorage.getItem(CONSENT_STORAGE_KEY);
    return value === "granted" || value === "denied" ? value : "none";
  } catch {
    // Safari private windows and Lockdown Mode can throw on access. Treating
    // that as "no choice recorded" is the conservative read: consent stays
    // denied and we ask again, rather than silently assuming granted.
    return "none";
  }
}

export function getConsentSnapshot(): ConsentState {
  if (cached === null) cached = read();
  return cached;
}

export function getConsentServerSnapshot(): ConsentState {
  return "unknown";
}

export function subscribeToConsent(onChange: () => void): () => void {
  const handler = () => {
    cached = null;
    onChange();
  };
  window.addEventListener("storage", handler);
  window.addEventListener(CONSENT_EVENT, handler);
  return () => {
    window.removeEventListener("storage", handler);
    window.removeEventListener(CONSENT_EVENT, handler);
  };
}

/**
 * Persist a choice and tell gtag about it.
 *
 * `gtag` is defined by the inline bootstrap in `Analytics`, which runs during
 * HTML parse — so it exists long before React has hydrated and a visitor can
 * click. The optional call covers dev and preview builds, where `Analytics`
 * renders nothing at all.
 */
export function writeConsent(choice: ConsentChoice): void {
  try {
    window.localStorage.setItem(CONSENT_STORAGE_KEY, choice);
  } catch {
    // A visitor who can't persist still gets the choice applied to this page
    // load; the banner will simply ask again next time.
  }

  cached = choice;
  window.dispatchEvent(new Event(CONSENT_EVENT));
  window.gtag?.("consent", "update", { analytics_storage: choice });
}
