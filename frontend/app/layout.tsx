import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { RootProvider } from "fumadocs-ui/provider/next";
import { siteConfig } from "@/lib/site-config";
import { SITE_URL, absoluteUrl, isProduction } from "@/lib/seo";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
  display: "swap",
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
  display: "swap",
});

const title = `${siteConfig.name} — ${siteConfig.tagline}`;

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: {
    default: title,
    template: `%s | ${siteConfig.name}`,
  },
  description: siteConfig.heroSub,
  applicationName: siteConfig.name,
  authors: [{ name: "Suryansh", url: "https://github.com/Suryansh-Codes2209" }],
  creator: "Suryansh",
  alternates: { canonical: absoluteUrl("/") },
  keywords: [
    "macOS download manager",
    "multi-threaded downloader",
    "HTTP range download",
    "IDM alternative for Mac",
    "yt-dlp Mac GUI",
    "resume downloads macOS",
    "open source download manager",
    "SwiftUI",
    "MacGet",
  ],
  category: "technology",
  // Preview deployments must not compete with the canonical site in search.
  robots: isProduction
    ? {
        index: true,
        follow: true,
        googleBot: {
          index: true,
          follow: true,
          "max-image-preview": "large",
          "max-snippet": -1,
        },
      }
    : { index: false, follow: false },
  openGraph: {
    title,
    description: siteConfig.heroSub,
    url: SITE_URL,
    siteName: siteConfig.name,
    locale: "en_US",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title,
    description: siteConfig.heroSub,
  },
};

export const viewport: Viewport = {
  themeColor: "#191512",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html
      lang="en"
      // The site is dark-only; `dark` is what fumadocs keys its tokens off.
      className={`dark ${geistSans.variable} ${geistMono.variable}`}
      suppressHydrationWarning
    >
      <body className="min-h-screen bg-ink font-sans text-cream antialiased">
        <RootProvider theme={{ enabled: false, forcedTheme: "dark" }}>
          {children}
        </RootProvider>
      </body>
    </html>
  );
}
