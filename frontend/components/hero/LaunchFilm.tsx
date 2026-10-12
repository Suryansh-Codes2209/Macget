"use client";

import { useEffect, useRef, useState } from "react";
import { useReducedMotion } from "motion/react";
import { Play, Volume2 } from "lucide-react";
import { siteConfig } from "@/lib/site-config";
import { cn } from "@/lib/cn";

const { film } = siteConfig;

/**
 * "preview" — muted, looping autoplay while on screen. Browsers only allow
 *   autoplay without sound, so this is the default.
 * "watching" — the visitor turned sound on or picked a chapter: native
 *   controls, and scrolling away no longer pauses/resumes it behind their back.
 * "idle" — reduced motion is on, so nothing moves until they press play.
 */
type Mode = "preview" | "watching" | "idle";

/**
 * The 60-second launch film, framed as a Mac window. The chapter rail doubles
 * as a table of contents for the page — each chip seeks the film to the scene
 * that covers that feature.
 */
export function LaunchFilm() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const reduceMotion = useReducedMotion() ?? false;
  const [chosenMode, setMode] = useState<Mode>("preview");
  const [time, setTime] = useState(0);
  const mode: Mode =
    chosenMode === "preview" && reduceMotion ? "idle" : chosenMode;

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    const onTime = () => setTime(video.currentTime);
    video.addEventListener("timeupdate", onTime);
    return () => video.removeEventListener("timeupdate", onTime);
  }, []);

  // Play the muted preview only while it's visible, so a 27 MB video isn't
  // decoding off-screen for the rest of the visit.
  useEffect(() => {
    const video = videoRef.current;
    if (!video || mode !== "preview") return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          video.muted = true;
          video.play().catch(() => setMode("idle"));
        } else {
          video.pause();
        }
      },
      { threshold: 0.25 },
    );
    observer.observe(video);
    return () => observer.disconnect();
  }, [mode]);

  function watch(at?: number) {
    const video = videoRef.current;
    if (!video) return;
    if (at !== undefined) video.currentTime = at;
    // Turning sound on mid-loop would land the visitor in the middle of the
    // film, so the first unmute restarts it from the top.
    else if (mode !== "watching") video.currentTime = 0;
    video.muted = false;
    video.loop = false;
    setMode("watching");
    // A rejected play() leaves the native controls visible, which is the
    // right fallback.
    video.play().catch(() => {});
  }

  // The active chapter is the last one whose start time we've passed.
  const active =
    mode === "idle"
      ? -1
      : film.chapters.reduce((acc, c, i) => (time >= c.at ? i : acc), 0);

  return (
    <figure id="film" className="scroll-mt-24">
      <div className="overflow-hidden rounded-[18px] border border-white/10 bg-abyss shadow-[0_50px_140px_-40px_rgba(0,0,0,0.95),0_0_0_1px_rgba(0,0,0,0.6)]">
        {/* Window chrome — the film is a product shot, so it sits in a Mac window. */}
        <div className="flex h-9 items-center gap-2 border-b border-white/[0.06] bg-surface px-4">
          <span className="size-3 rounded-full bg-[#ff5f57]" />
          <span className="size-3 rounded-full bg-[#febc2e]" />
          <span className="size-3 rounded-full bg-[#28c840]" />
          <span className="ml-3 truncate text-xs text-mute">
            MacGet in 60 seconds
          </span>
        </div>

        <div className="relative aspect-video">
          <video
            ref={videoRef}
            src={film.src}
            poster={film.poster}
            muted
            loop
            playsInline
            preload="metadata"
            controls={mode === "watching"}
            className="absolute inset-0 h-full w-full"
            aria-label="MacGet launch film: a 60-second tour of parallel downloads, the inspector, adaptive limits, connection bonding and resume."
          />
          {mode === "preview" && (
            <button
              type="button"
              onClick={() => watch()}
              className="absolute bottom-3 right-3 flex items-center gap-2 rounded-pill bg-black/60 px-3.5 py-2 text-xs font-medium text-cream backdrop-blur-md transition-colors hover:bg-black/80 sm:bottom-5 sm:right-5 sm:text-sm"
            >
              <Volume2 className="size-4" />
              Watch with sound
            </button>
          )}
          {mode === "idle" && (
            <button
              type="button"
              onClick={() => watch()}
              className="group absolute inset-0 flex items-center justify-center bg-gradient-to-t from-black/50 via-black/10 to-transparent"
              aria-label="Play the 60-second tour, with sound"
            >
              <span className="flex items-center gap-3 rounded-pill bg-cream py-3 pl-4 pr-5 text-sm font-semibold text-brand-umber shadow-[0_20px_50px_-10px_rgba(0,0,0,0.8)] transition-transform duration-200 group-hover:scale-[1.04]">
                <span className="flex size-8 items-center justify-center rounded-full bg-brand-amber text-abyss">
                  <Play className="ml-0.5 size-4 fill-current" />
                </span>
                Watch the tour
                <span className="font-normal text-brand-umber/70">1:01</span>
              </span>
            </button>
          )}
        </div>
      </div>

      <figcaption className="mt-4">
        <span className="sr-only">Jump to a chapter of the film:</span>
        <ol className="-mx-6 flex gap-2 overflow-x-auto px-6 pb-2 [scrollbar-width:none] sm:mx-0 sm:flex-wrap sm:justify-center sm:px-0">
          {film.chapters.map((chapter, i) => (
            <li key={chapter.label} className="shrink-0">
              <button
                type="button"
                onClick={() => watch(chapter.at)}
                aria-current={i === active ? "true" : undefined}
                className={cn(
                  "flex items-center gap-2 rounded-pill border px-3 py-1.5 text-xs transition-colors",
                  i === active
                    ? "border-brand-amber/60 bg-brand-amber/15 text-cream"
                    : "border-line text-cream-dim hover:border-white/20 hover:text-cream",
                )}
              >
                <span className="tabular-nums text-mute">
                  {formatTime(chapter.at)}
                </span>
                {chapter.label}
              </button>
            </li>
          ))}
        </ol>
      </figcaption>
    </figure>
  );
}

function formatTime(seconds: number) {
  const s = Math.floor(seconds);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}
