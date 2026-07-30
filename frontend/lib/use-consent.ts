"use client";

import { useSyncExternalStore } from "react";
import {
  getConsentServerSnapshot,
  getConsentSnapshot,
  subscribeToConsent,
  type ConsentState,
} from "./consent";

/**
 * Current analytics consent, kept in sync across components and browser tabs.
 *
 * Split out of `consent.ts` because that module is imported by the `Analytics`
 * server component, and a module that imports a React hook can't cross that
 * boundary at all — see the note at the top of `consent.ts`.
 *
 * `useSyncExternalStore` rather than `useState` + `useEffect`: the value lives
 * in localStorage, outside React, and reading it in an effect would both be the
 * pattern React 19 lints against and leave a render where the answer is wrong.
 */
export function useConsent(): ConsentState {
  return useSyncExternalStore(
    subscribeToConsent,
    getConsentSnapshot,
    getConsentServerSnapshot,
  );
}
