import type { ReactNode } from "react";
import Image from "next/image";
import { DocsLayout } from "fumadocs-ui/layouts/docs";
import { source } from "@/lib/source";
import { siteConfig } from "@/lib/site-config";

export default function Layout({ children }: { children: ReactNode }) {
  return (
    <DocsLayout
      tree={source.pageTree}
      nav={{
        title: (
          <span className="inline-flex items-center gap-2">
            <Image
              src="/macget-icon.svg"
              alt=""
              width={24}
              height={24}
              className="size-6 rounded-md"
            />
            <span className="font-semibold text-cream">{siteConfig.name}</span>
            <span className="rounded-pill border border-line px-2 py-0.5 font-mono text-[10px] text-mute">
              v{siteConfig.version}
            </span>
          </span>
        ),
        url: "/",
      }}
      links={[
        { text: "Install", url: "/install" },
        { text: "Changelog", url: "/changelog" },
        { text: "GitHub", url: siteConfig.repoUrl, external: true },
      ]}
    >
      {children}
    </DocsLayout>
  );
}
