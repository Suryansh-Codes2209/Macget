import Link from "next/link";
import { PageShell } from "@/components/layout/PageShell";
import { Prose } from "@/components/layout/Prose";
import { pageMetadata } from "@/lib/seo";
import { siteConfig } from "@/lib/site-config";

export const metadata = pageMetadata({
  title: "Privacy Policy",
  description:
    "MacGet collects nothing. No analytics, no telemetry, no accounts, no server. This policy documents exactly what stays on your Mac, the few cases where MacGet touches the network, and what the browser extension's permissions are actually used for.",
  path: "/privacy",
});

const EFFECTIVE_DATE = "27 July 2026";

export default function PrivacyPage() {
  return (
    <PageShell
      eyebrow="Legal"
      title="Privacy Policy"
      lede={
        <>
          MacGet has no analytics, no telemetry, no accounts, and no backend.
          That makes this policy short — so instead of padding it, it documents
          precisely what is stored, what touches the network, and why the
          browser extension asks for the permissions it does.
        </>
      }
      meta={
        <>
          Effective {EFFECTIVE_DATE} · Applies to MacGet {siteConfig.version},
          the browser extension, and this website
        </>
      }
    >
      <Prose>
        <h2>The short version</h2>

        <p>
          MacGet does not collect, transmit, or sell any personal information.
          There is no analytics SDK, no crash reporter, no remote logging, and
          no account system. There is no MacGet server for your data to be sent
          to, because none exists.
        </p>

        <p>
          Everything below is verifiable — MacGet is{" "}
          <a href={siteConfig.repoUrl} target="_blank" rel="noreferrer noopener">
            open source under the MIT license
          </a>
          , so you don&apos;t have to take this document&apos;s word for any of
          it.
        </p>

        <h2>What MacGet stores, and where</h2>

        <p>
          All application state lives on your Mac, in{" "}
          <code>~/Library/Application Support/{siteConfig.binary}/</code>:
        </p>

        <ul>
          <li>
            <code>queue.json</code> — your download queue: URLs, destination
            paths, per-chunk progress, and status.
          </li>
          <li>
            <code>settings.json</code> — your preferences, including the default
            download folder and any proxy you configured.
          </li>
          <li>
            <code>host_caps.json</code> — the parallelism limit MacGet learned
            for each host it has downloaded from. Hostnames only.
          </li>
          <li>
            <code>incoming/</code> — the handoff directory the browser extension
            writes into. Entries are consumed and removed as they are ingested.
          </li>
          <li>
            Partial downloads, as <code>.{siteConfig.binary.toLowerCase()}-partial</code>{" "}
            files alongside their destination, until they finish.
          </li>
        </ul>

        <p>
          <strong>Credentials are the exception.</strong> Usernames and
          passwords you save for authenticated downloads are stored in the{" "}
          <strong>macOS Keychain</strong>, not in any of the files above and not
          in plain text.
        </p>

        <p>
          None of this is backed up to, synced with, or reported to anyone. To
          erase all of it, delete that directory and remove any MacGet entries
          from Keychain Access — the{" "}
          <Link href="/install">install guide</Link> has the exact commands.
        </p>

        <h2>When MacGet uses the network</h2>

        <p>
          A download manager obviously makes network requests. Here is the
          complete list of what it connects to and why.
        </p>

        <h3>1. The servers you download from</h3>

        <p>
          When you download a file, MacGet connects to that file&apos;s host —
          the same connection your browser would make, split across multiple
          HTTP-Range requests. Those servers see what any HTTP server sees: your
          IP address, a{" "}
          <code>{siteConfig.binary}/{siteConfig.version}</code> User-Agent, and
          any credentials or cookies required for that specific download. MacGet
          adds nothing else and sends nothing to anyone but that host.
        </p>

        <h3>2. Update checks</h3>

        <p>
          MacGet uses Sparkle to fetch a signed appcast feed hosted on GitHub
          Pages. This is an ordinary HTTPS request, so GitHub can observe your
          IP address and User-Agent, subject to{" "}
          <a
            href="https://docs.github.com/en/site-policy/privacy-policies/github-privacy-statement"
            target="_blank"
            rel="noreferrer noopener"
          >
            GitHub&apos;s privacy statement
          </a>
          . The request contains the current app version so it can tell whether
          an update applies. It carries no identifier for you or your machine.
          You can disable automatic checks in MacGet&apos;s update settings.
        </p>

        <h3>3. Media extraction, if you turn it on</h3>

        <p>
          MacGet bundles yt-dlp for video and audio downloads.{" "}
          <strong>This is off by default.</strong> When enabled, media links are
          handed to yt-dlp, which contacts the media site directly to resolve
          formats — again, only that site. Leaving the feature off means yt-dlp
          is never invoked.
        </p>

        <p>
          There is no fourth case. MacGet makes no other outbound connections.
        </p>

        <h2>The browser extension</h2>

        <p>
          The optional capture extension needs broad-looking permissions, and
          you should know what each is for before installing it. It requests{" "}
          <code>downloads</code>, <code>cookies</code>, <code>webRequest</code>,{" "}
          <code>tabs</code>, <code>nativeMessaging</code>,{" "}
          <code>storage</code>, and host access to all URLs.
        </p>

        <p>
          That set exists because the extension has to notice a download
          starting on any site, and then reproduce it faithfully outside the
          browser. When a download begins, it collects the URL, the suggested
          filename, the referrer, the file size, the MIME type, your browser&apos;s
          User-Agent, and the cookies for that URL.
        </p>

        <p>
          <strong>Cookies are the sensitive part, so to be exact:</strong> the
          extension calls the browser&apos;s cookie API scoped to the specific
          download URL. It reads the cookies that would be sent to that one
          address, not your cookie jar. They are included because that is what
          makes a download from behind a login work outside the browser —
          without them, a session-protected file returns an error page instead
          of the file.
        </p>

        <p>
          <strong>Where that data goes:</strong> to MacGet on the same machine,
          over Chrome and Firefox&apos;s native-messaging channel, into{" "}
          <code>~/Library/Application Support/{siteConfig.binary}/incoming/</code>
          . The extension contains no code that contacts a remote server — no{" "}
          <code>fetch</code>, no XHR, no endpoint of any kind. The captured data
          never leaves your computer, and it goes to no one but MacGet.
        </p>

        <p>
          The extension is entirely optional. MacGet works without it, and
          removing it from your browser ends any collection immediately.
        </p>

        <h2>This website</h2>

        <p>
          <a href={siteConfig.url}>{siteConfig.url.replace("https://", "")}</a>{" "}
          is a static site hosted on Vercel. It sets no cookies, runs no
          analytics, and has no tracking pixels or third-party embeds. Vercel
          keeps standard server logs (IP address, User-Agent, requested URL) as
          part of serving the site, described in{" "}
          <a
            href="https://vercel.com/legal/privacy-policy"
            target="_blank"
            rel="noreferrer noopener"
          >
            Vercel&apos;s privacy policy
          </a>
          . Fonts are self-hosted; nothing loads from a third-party CDN.
        </p>

        <h2>Children</h2>

        <p>
          MacGet is a general-purpose developer tool and is not directed at
          children. Since it collects no personal information from anyone, it
          collects none from children either.
        </p>

        <h2>Changes to this policy</h2>

        <p>
          If MacGet&apos;s behaviour ever changes in a way that affects this
          document, the policy will be updated along with it and the effective
          date above will change. Because the site is versioned in the same
          repository as the app, the full history of this page is public in{" "}
          <a href={siteConfig.repoUrl} target="_blank" rel="noreferrer noopener">
            git
          </a>
          .
        </p>

        <h2>Contact</h2>

        <p>
          Questions about privacy: <a href={`mailto:${siteConfig.contactEmail}`}>{siteConfig.contactEmail}</a>
          . For suspected vulnerabilities, please use the{" "}
          <a href={siteConfig.securityUrl} target="_blank" rel="noreferrer noopener">
            security policy
          </a>{" "}
          rather than a public issue.
        </p>
      </Prose>
    </PageShell>
  );
}
