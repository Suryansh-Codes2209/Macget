import Script from "next/script";
import { CONSENT_STORAGE_KEY } from "@/lib/consent";
import { ConsentBanner } from "./ConsentBanner";

/** GA4 measurement ID for macget.suryansh.work. */
const GA_MEASUREMENT_ID = "G-P1YPGV6QYT";

/**
 * Analytics runs on the production deploy only.
 *
 * Both halves are load-bearing. Without the NODE_ENV check, every `bun dev`
 * page view — and there are a lot of them, one per hot reload — lands in the
 * live GA property. Without the VERCEL_ENV check, preview deploys report as
 * real traffic. Note that VERCEL_ENV is undefined off-Vercel, so a production
 * build hosted anywhere else still reports.
 */
const analyticsEnabled =
  process.env.NODE_ENV === "production" &&
  (process.env.VERCEL_ENV === undefined ||
    process.env.VERCEL_ENV === "production");

/**
 * Google Analytics 4, gated by Consent Mode v2.
 *
 * Storage starts `denied` for everyone. In that state gtag.js writes nothing to
 * the device and sends cookieless pings, which still carry page views, referrer,
 * device, and the visitor's country (Google derives country from the IP
 * server-side and discards it, so geography never depended on the cookie).
 * Allowing analytics upgrades `analytics_storage` to `granted`, at which point
 * GA sets its `_ga` client ID and *user* counts become real counts instead of
 * modeled estimates — which is the only thing consent actually buys here.
 *
 * Two orderings in here are load-bearing, and both fail silently if broken:
 *
 * 1. The inline block is a plain `<script>`, not a `next/script`, so it runs
 *    during HTML parse — before the `afterInteractive` gtag.js is injected.
 *    Its calls queue into `dataLayer`, which gtag.js drains in order on load,
 *    so `consent` is always processed before `config`. Routing the consent
 *    default through `next/script` would race it against the library, and a
 *    `config` that wins that race sets a cookie before being told not to.
 *
 * 2. The stored choice is read *synchronously here*, not in the banner's
 *    effect. A returning visitor who already allowed analytics must start the
 *    page load already granted; deferring it to React would send that page's
 *    first hit cookieless and only upgrade afterwards, splitting every session
 *    across two client IDs.
 */
export function Analytics() {
  if (!analyticsEnabled) return null;

  // Reading storage can throw (Safari private mode, Lockdown Mode). A throw
  // here would abort the whole bootstrap and take analytics down with it, so
  // failure falls through to the denied default.
  const bootstrap = `window.dataLayer = window.dataLayer || [];
function gtag(){dataLayer.push(arguments);}
var c = null;
try { c = window.localStorage.getItem('${CONSENT_STORAGE_KEY}'); } catch (e) {}
gtag('consent', 'default', {
  ad_storage: 'denied',
  ad_user_data: 'denied',
  ad_personalization: 'denied',
  analytics_storage: c === 'granted' ? 'granted' : 'denied'
});
gtag('set', 'ads_data_redaction', true);
gtag('js', new Date());
gtag('config', '${GA_MEASUREMENT_ID}');`;

  return (
    <>
      {/* Built from module constants, never from user input. */}
      <script dangerouslySetInnerHTML={{ __html: bootstrap }} />
      <Script
        src={`https://www.googletagmanager.com/gtag/js?id=${GA_MEASUREMENT_ID}`}
        strategy="afterInteractive"
      />
      <ConsentBanner />
    </>
  );
}
