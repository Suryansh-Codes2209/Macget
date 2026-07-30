"use client";

import { useEffect, useRef, useState } from "react";
import { Check, Copy } from "lucide-react";
import { cn } from "@/lib/cn";

interface CopyCommandProps {
  command: string;
  className?: string;
  /** Shown before the command, dimmed and unselectable. */
  prompt?: string;
  label?: string;
}

export function CopyCommand({
  command,
  className,
  prompt = "$",
  label = "Copy command",
}: CopyCommandProps) {
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // The timeout outlives the click; clear it so a copy right before an unmount
  // doesn't setState on a gone component.
  useEffect(() => () => {
    if (timer.current) clearTimeout(timer.current);
  }, []);

  async function copy() {
    try {
      await navigator.clipboard.writeText(command);
    } catch {
      // Clipboard is permission-gated and absent over plain http — the command
      // is still selectable, so a failure just means no confirmation tick.
      return;
    }
    setCopied(true);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => setCopied(false), 2000);
  }

  return (
    <div
      className={cn(
        "group flex items-center gap-3 rounded-card border border-line bg-white/[0.04] py-2.5 pl-4 pr-2.5 transition-colors hover:border-white/20",
        className,
      )}
    >
      <code
        data-unstyled
        className="min-w-0 flex-1 overflow-x-auto whitespace-nowrap font-mono text-[13px] leading-relaxed text-cream"
      >
        <span className="select-none pr-2 text-mute">{prompt}</span>
        {command}
      </code>
      <button
        type="button"
        onClick={copy}
        aria-label={label}
        className="shrink-0 rounded-md p-2 text-mute transition-colors hover:bg-white/[0.08] hover:text-cream focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand-honey"
      >
        {copied ? (
          <Check className="size-4 text-brand-honey" strokeWidth={2.4} />
        ) : (
          <Copy className="size-4" strokeWidth={2} />
        )}
      </button>
      <span aria-live="polite" className="sr-only">
        {copied ? "Copied to clipboard" : ""}
      </span>
    </div>
  );
}
