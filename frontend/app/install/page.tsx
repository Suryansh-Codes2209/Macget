import Link from "next/link";
import { ArrowDownToLine } from "lucide-react";
import { PageShell } from "@/components/layout/PageShell";
import { Prose } from "@/components/layout/Prose";
import { GradientButton } from "@/components/ui/GradientButton";
import { JsonLd } from "@/components/seo/JsonLd";
import { breadcrumbSchema, pageMetadata } from "@/lib/seo";
import { siteConfig } from "@/lib/site-config";

export const metadata = pageMetadata({
  title: "Install MacGet on macOS",
  description:
    "How to install MacGet: one Homebrew command with no Gatekeeper prompt, or a DMG download with a one-time first-launch warning. MacGet is distributed free and un-notarized, so macOS asks once before it will open a manually-installed build.",
  path: "/install",
});

export default function InstallPage() {
  return (
    <PageShell
      eyebrow="Installation"
      title="Install MacGet"
      lede={
        <>
          One Homebrew command and you&apos;re done — no Gatekeeper prompt.
          Prefer to install by hand from the DMG instead? That takes two
          minutes and one first-launch warning. This page covers both paths,
          plus how updates work afterwards.
        </>
      }
      meta={
        <>
          Version {siteConfig.version} · Requires {siteConfig.minOS} or later ·
          Apple silicon only
        </>
      }
    >
      <JsonLd
        schema={breadcrumbSchema([
          { name: "Home", path: "/" },
          { name: "Install", path: "/install" },
        ])}
      />

      <div className="mb-12 flex flex-wrap gap-3">
        <GradientButton
          href={siteConfig.downloadUrl}
          external
          size="lg"
          variant="primary"
        >
          <ArrowDownToLine className="size-5" strokeWidth={2.4} />
          Download the latest release
        </GradientButton>
      </div>

      <Prose>
        <h2>Before you install</h2>

        <p>
          Three things worth knowing before you double-click anything.
        </p>

        <p>
          <strong>You need macOS {siteConfig.minOS} or later.</strong> MacGet is
          built against Tahoe APIs and will not launch on earlier systems.
          Check with  → About This Mac.
        </p>

        <p>
          <strong>Download only from the official releases page.</strong> The
          only place MacGet is published is{" "}
          <a href={siteConfig.releasesUrl} target="_blank" rel="noreferrer noopener">
            the GitHub releases page
          </a>
          . A build of a download manager from anywhere else is not one you
          should trust.
        </p>

        <p>
          <strong>
            MacGet is not notarized, and macOS will tell you so.
          </strong>{" "}
          Apple notarization requires a paid Apple Developer account
          ($99/year). MacGet is free and un-funded, so it ships without it.
          That has one visible consequence — a warning the first time you open
          the app — and it is worth being precise about what that warning does
          and doesn&apos;t mean.
        </p>

        <p>
          It means Apple has not scanned this specific build. It does not mean
          macOS detected anything wrong with it. What you get instead is a
          different set of guarantees: the{" "}
          <a href={siteConfig.repoUrl} target="_blank" rel="noreferrer noopener">
            full source is public
          </a>
          , releases are built from it, Hardened Runtime is enabled, and every
          automatic update is checked against an EdDSA signature before it is
          allowed to install. If that tradeoff isn&apos;t one you want to make,
          building from source is always an option.
        </p>

        <h2>Installing</h2>

        <h3>Homebrew (recommended)</h3>

        <pre>
          <code>brew install --cask suryansh-codes2209/macget/macget</code>
        </pre>

        <p>
          Requires {siteConfig.minOS} or later on Apple silicon. The cask
          removes the quarantine attribute after install, so there is no
          Gatekeeper prompt and no &ldquo;Open Anyway&rdquo; step — the
          &ldquo;First launch — the Gatekeeper prompt&rdquo; section below
          doesn&apos;t apply to you.
        </p>

        <h3>Manually, from the DMG</h3>

        <ol>
          <li>
            Download <code>{siteConfig.binary}.dmg</code> from the releases
            page.
          </li>
          <li>Open the DMG.</li>
          <li>
            Drag <strong>{siteConfig.binary}</strong> into your{" "}
            <strong>Applications</strong> folder.
          </li>
          <li>Eject the DMG.</li>
        </ol>

        <p>
          Keep the app in <code>/Applications</code>. The browser extension&apos;s
          native-messaging host is registered at the path MacGet last launched
          from, so a stable location keeps browser capture working.
        </p>

        <h2>First launch — the Gatekeeper prompt</h2>

        <p>
          Open MacGet from Applications. macOS will refuse the first time and
          show:
        </p>

        <blockquote className="rounded-card border border-line bg-surface/60 p-5 text-sm text-cream">
          &ldquo;{siteConfig.binary}&rdquo; can&apos;t be opened because Apple
          cannot check it for malicious software.
        </blockquote>

        <p>This is the expected behaviour described above. To get past it:</p>

        <ol>
          <li>
            Click <strong>Done</strong> on the dialog. Don&apos;t move the app
            to the Trash.
          </li>
          <li>
            Open <strong>System Settings</strong> →{" "}
            <strong>Privacy &amp; Security</strong>.
          </li>
          <li>
            Scroll to the <strong>Security</strong> section. You&apos;ll see a
            line saying &ldquo;{siteConfig.binary}&rdquo; was blocked. Click{" "}
            <strong>Open Anyway</strong>.
          </li>
          <li>
            Authenticate with Touch ID or your password, then click{" "}
            <strong>Open</strong> on the final confirmation.
          </li>
        </ol>

        <p>
          MacGet opens, and macOS remembers the decision. Every later launch is
          normal — you will not see this again for this app.
        </p>

        <h3>The terminal alternative</h3>

        <p>
          If you would rather not click through System Settings, you can remove
          the quarantine attribute directly:
        </p>

        <pre>
          <code>
            xattr -dr com.apple.quarantine /Applications/{siteConfig.binary}.app
          </code>
        </pre>

        <p>
          Worth understanding what that actually does, because it&apos;s a
          command people paste without reading. When you download a file,
          macOS tags it with an extended attribute called{" "}
          <code>com.apple.quarantine</code>. That tag is what triggers the
          Gatekeeper check on first open. The command removes the tag
          recursively from the app bundle, so the check never fires.
        </p>

        <p>
          It is the same decision as clicking Open Anyway — you are telling
          macOS you trust this app — but it is worth being deliberate about it.
          Run it against apps you have chosen to trust, from a source you
          verified, and never as a reflex on anything that fails to open.
        </p>

        <h2>Checking it worked</h2>

        <p>
          MacGet should open to an empty download queue. Paste a direct file URL
          into the Add sheet and start it; you should see chunks appear with
          live progress. If the app bounces in the Dock and quits, you are most
          likely on a macOS older than {siteConfig.minOS}.
        </p>

        <h2>Updates after this</h2>

        <p>
          You don&apos;t come back here to update. MacGet uses{" "}
          <a href="https://sparkle-project.org" target="_blank" rel="noreferrer noopener">
            Sparkle
          </a>
          , which checks a signed appcast feed on a schedule and offers new
          versions in-app. You can also check on demand from{" "}
          <strong>{siteConfig.name} → Check for Updates…</strong> in the menu
          bar.
        </p>

        <p>
          Every update is signed with an EdDSA key and the signature is verified
          before installation, so a tampered or corrupted download is rejected.
          This is independent of Apple notarization — it is why auto-updates are
          still trustworthy on an un-notarized build. Updates install without
          repeating the Gatekeeper step.
        </p>

        <h2>Uninstalling</h2>

        <p>To remove MacGet completely:</p>

        <ol>
          <li>
            Quit MacGet, then drag <code>/Applications/{siteConfig.binary}.app</code>{" "}
            to the Trash.
          </li>
          <li>
            Delete its data directory, which holds the queue, settings, learned
            host limits, and any partial downloads:
            <pre className="mt-3">
              <code>
                rm -rf ~/Library/Application\ Support/{siteConfig.binary}
              </code>
            </pre>
          </li>
          <li>
            If you saved download credentials, remove the{" "}
            <strong>{siteConfig.binary}</strong> entries from Keychain Access.
          </li>
          <li>
            If you installed the browser extension, remove it from your browser
            too.
          </li>
        </ol>

        <h2>Still stuck?</h2>

        <p>
          The <Link href="/docs">documentation</Link> covers configuration and
          troubleshooting in more depth. If something is genuinely broken,{" "}
          <a href={siteConfig.issuesUrl} target="_blank" rel="noreferrer noopener">
            open an issue
          </a>{" "}
          — and for anything security-related, please follow the{" "}
          <a href={siteConfig.securityUrl} target="_blank" rel="noreferrer noopener">
            security policy
          </a>{" "}
          rather than filing publicly.
        </p>
      </Prose>
    </PageShell>
  );
}
