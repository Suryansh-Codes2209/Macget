import { siteConfig } from "@/lib/site-config";

/**
 * The shipping version, for use inside MDX as `<Version />`.
 *
 * Docs prose that names the release has to come from `siteConfig`, not from a
 * literal. A hardcoded one survived the 1.3.0 bump and left the docs landing
 * page advertising v1.2.0 to everyone who read it — a plain-text string in MDX
 * is invisible to every version-bump grep that looks at code.
 */
export function Version({ prefix = "v" }: { prefix?: string }) {
  return (
    <>
      {prefix}
      {siteConfig.version}
    </>
  );
}
