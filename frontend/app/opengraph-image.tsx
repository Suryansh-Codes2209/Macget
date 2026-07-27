import { ImageResponse } from "next/og";
import { siteConfig } from "@/lib/site-config";

export const alt = `${siteConfig.name} — ${siteConfig.tagline}`;
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

/**
 * The site previously declared a `summary_large_image` Twitter card with no
 * image attached, which renders as a bare link. This is that image.
 *
 * Satori requires an explicit `display` on every element with more than one
 * child, so every div below sets it.
 */
export default function OpengraphImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          background: "#060812",
          backgroundImage:
            "radial-gradient(circle at 50% 0%, rgba(10,132,255,0.35), transparent 60%)",
          padding: 72,
          fontFamily: "system-ui, -apple-system, sans-serif",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 20 }}>
          <div
            style={{
              display: "flex",
              width: 64,
              height: 64,
              borderRadius: 16,
              background:
                "linear-gradient(180deg, #5ac8fa 0%, #0a84ff 50%, #0033b0 100%)",
            }}
          />
          <div style={{ display: "flex", color: "#f5f8ff", fontSize: 40, fontWeight: 600 }}>
            {siteConfig.name}
          </div>
          <div
            style={{
              display: "flex",
              color: "#8a95b8",
              fontSize: 24,
              border: "1px solid rgba(216,232,255,0.18)",
              borderRadius: 999,
              padding: "6px 18px",
            }}
          >
            {`v${siteConfig.version}`}
          </div>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
          <div
            style={{
              display: "flex",
              color: "#f5f8ff",
              fontSize: 84,
              fontWeight: 600,
              letterSpacing: -2,
              lineHeight: 1.05,
            }}
          >
            {"Download. In parallel."}
          </div>
          <div
            style={{
              display: "flex",
              color: "#d8e8ff",
              fontSize: 32,
              lineHeight: 1.4,
              maxWidth: 900,
            }}
          >
            {siteConfig.tagline}
          </div>
        </div>

        <div style={{ display: "flex", gap: 28, color: "#8a95b8", fontSize: 24 }}>
          {["16 parallel chunks", "Zero telemetry", "MIT licensed", `${siteConfig.minOS}+`].map(
            (item) => (
              <div key={item} style={{ display: "flex" }}>
                {item}
              </div>
            ),
          )}
        </div>
      </div>
    ),
    size,
  );
}
