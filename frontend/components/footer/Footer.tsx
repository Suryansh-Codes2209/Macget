import Image from "next/image";
import { Github } from "lucide-react";
import { siteConfig } from "@/lib/site-config";

export function Footer() {
  const year = new Date().getFullYear();
  return (
    <footer className="relative border-t border-line bg-abyss">
      <div className="mx-auto flex max-w-7xl flex-col gap-10 px-6 py-14 lg:px-10">
        <div className="flex flex-col items-start justify-between gap-8 lg:flex-row lg:items-center">
          <div className="flex items-center gap-3">
            <Image
              src="/macget-icon.svg"
              alt=""
              width={40}
              height={40}
              className="size-10 rounded-xl"
            />
            <div>
              <div className="text-base font-semibold text-frost">
                {siteConfig.name}
              </div>
              <div className="text-xs text-mute">
                {siteConfig.tagline}
              </div>
            </div>
          </div>

          <div className="flex flex-wrap items-center gap-4 text-sm">
            <a
              href={siteConfig.repoUrl}
              target="_blank"
              rel="noreferrer noopener"
              className="inline-flex items-center gap-2 rounded-pill border border-line bg-white/[0.04] px-4 py-2 text-frost-dim transition-colors hover:border-white/20 hover:text-frost"
            >
              <Github className="size-4" />
              GitHub
            </a>
            <a
              href={siteConfig.licenseUrl}
              target="_blank"
              rel="noreferrer noopener"
              className="rounded-pill px-4 py-2 text-frost-dim transition-colors hover:text-frost"
            >
              MIT License
            </a>
            <a
              href={siteConfig.downloadUrl}
              target="_blank"
              rel="noreferrer noopener"
              className="rounded-pill bg-frost px-4 py-2 font-medium text-brand-cobalt transition-transform hover:-translate-y-0.5"
            >
              Download
            </a>
          </div>
        </div>

        <div className="border-t border-line/60 pt-6">
          <p className="text-xs leading-relaxed text-mute">
            {siteConfig.disclaimer}
          </p>
          <p className="mt-3 text-xs text-mute">
            © {year} {siteConfig.name}. Released under the MIT License.
            Requires {siteConfig.minOS} or later.
          </p>
        </div>
      </div>
    </footer>
  );
}
