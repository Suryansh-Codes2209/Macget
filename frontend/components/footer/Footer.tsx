import Image from "next/image";
import Link from "next/link";
import { Github, Linkedin } from "lucide-react";
import { siteConfig } from "@/lib/site-config";

export function Footer() {
  const year = new Date().getFullYear();

  return (
    <footer className="relative border-t border-line bg-abyss">
      <div className="mx-auto flex max-w-7xl flex-col gap-12 px-6 py-14 lg:px-10">
        <div className="grid gap-10 lg:grid-cols-[1.4fr_repeat(4,1fr)]">
          <div className="flex flex-col gap-4">
            <Link href="/" className="flex items-center gap-3">
              <Image
                src="/macget-icon.svg"
                alt=""
                width={40}
                height={40}
                className="size-10 rounded-xl"
              />
              <div>
                <div className="text-base font-semibold text-cream">
                  {siteConfig.name}
                </div>
                <div className="text-xs text-mute">v{siteConfig.version}</div>
              </div>
            </Link>
            <p className="max-w-xs text-sm leading-relaxed text-mute">
              {siteConfig.tagline}
            </p>
            <div className="flex flex-wrap gap-2">
              <a
                href={siteConfig.repoUrl}
                target="_blank"
                rel="noreferrer noopener"
                className="inline-flex w-fit items-center gap-2 rounded-pill border border-line bg-white/[0.04] px-4 py-2 text-sm text-cream-dim transition-colors hover:border-white/20 hover:text-cream"
              >
                <Github className="size-4" />
                GitHub
              </a>
              <a
                href={siteConfig.linkedinUrl}
                target="_blank"
                rel="noreferrer noopener"
                className="inline-flex w-fit items-center gap-2 rounded-pill border border-line bg-white/[0.04] px-4 py-2 text-sm text-cream-dim transition-colors hover:border-white/20 hover:text-cream"
              >
                <Linkedin className="size-4" />
                LinkedIn
              </a>
            </div>
          </div>

          {siteConfig.footerNav.map((group) => (
            <nav key={group.title} aria-label={group.title}>
              <h2 className="text-xs font-semibold uppercase tracking-wider text-cream">
                {group.title}
              </h2>
              <ul className="mt-4 flex flex-col gap-2.5">
                {group.links.map((link) => (
                  <li key={link.href}>
                    {"external" in link && link.external ? (
                      <a
                        href={link.href}
                        target="_blank"
                        rel="noreferrer noopener"
                        className="text-sm text-mute transition-colors hover:text-cream"
                      >
                        {link.label}
                      </a>
                    ) : (
                      <Link
                        href={link.href}
                        className="text-sm text-mute transition-colors hover:text-cream"
                      >
                        {link.label}
                      </Link>
                    )}
                  </li>
                ))}
              </ul>
            </nav>
          ))}
        </div>

        <div className="flex flex-col gap-3 border-t border-line/60 pt-6">
          <p className="text-xs leading-relaxed text-mute">
            {siteConfig.disclaimer}
          </p>
          <p className="text-xs leading-relaxed text-mute">
            Distributed free and un-notarized — first launch needs a one-time
            Gatekeeper approval.{" "}
            <Link href="/install" className="text-cream-dim underline underline-offset-4 hover:text-cream">
              See the install guide
            </Link>
            .
          </p>
          <p className="text-xs text-mute">
            © {year} {siteConfig.name}. Released under the MIT License. Requires{" "}
            {siteConfig.minOS} or later.
          </p>
        </div>
      </div>
    </footer>
  );
}
