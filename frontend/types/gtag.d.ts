/** Minimal ambient type for the `gtag` shim defined in `components/seo/Analytics.tsx`. */
declare global {
  interface Window {
    gtag?: (...args: unknown[]) => void;
    dataLayer?: unknown[];
  }
}

export {};
