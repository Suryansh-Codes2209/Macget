"use client";

import {
  motion,
  useMotionValue,
  useReducedMotion,
  useTransform,
  animate,
} from "motion/react";
import { useEffect, useState } from "react";

const VIEW_W = 480;
const VIEW_H = 540;

const LANES = [
  { x: 80, label: "T1", size: "168 MB", duration: 1.6, fillTarget: 0.9, color: "url(#packetA)" },
  { x: 180, label: "T2", size: "192 MB", duration: 2.1, fillTarget: 0.7, color: "url(#packetA)" },
  { x: 280, label: "T3", size: "144 MB", duration: 1.3, fillTarget: 0.6, color: "url(#packetA)" },
  { x: 380, label: "T4", size: "201 MB", duration: 2.4, fillTarget: 0.8, color: "url(#packetA)" },
] as const;

const LANE_W = 56;
const LANE_TOP = 60;
const LANE_BOTTOM = 360;
const LANE_HEIGHT = LANE_BOTTOM - LANE_TOP;
const PACKET_W = 36;
const PACKET_H = 10;

const MBPS_CYCLE = [28.4, 36.1, 41.7, 38.4, 33.0, 35.7, 40.2];

export function ChunkVisualization() {
  const reduceMotion = useReducedMotion() ?? false;

  const percent = useMotionValue(reduceMotion ? 71 : 0);
  const mbps = useMotionValue(reduceMotion ? 38.4 : MBPS_CYCLE[0]);

  const percentText = useTransform(percent, (v) => `${Math.round(v)}%`);
  const mbpsText = useTransform(mbps, (v) => `${v.toFixed(1)} MB/s`);

  // React-rendered string mirrors of the motion values so SVG <text> updates.
  const [percentDisplay, setPercentDisplay] = useState(reduceMotion ? "71%" : "0%");
  const [mbpsDisplay, setMbpsDisplay] = useState(
    reduceMotion ? "38.4 MB/s" : `${MBPS_CYCLE[0].toFixed(1)} MB/s`,
  );

  useEffect(() => {
    const unsubPct = percentText.on("change", setPercentDisplay);
    const unsubMbps = mbpsText.on("change", setMbpsDisplay);
    return () => {
      unsubPct();
      unsubMbps();
    };
  }, [percentText, mbpsText]);

  useEffect(() => {
    if (reduceMotion) return;

    const pctControls = animate(percent, [0, 100], {
      duration: 9,
      ease: "easeInOut",
      repeat: Infinity,
      repeatType: "loop",
    });

    const mbpsControls = animate(mbps, MBPS_CYCLE, {
      duration: 7,
      ease: "easeInOut",
      repeat: Infinity,
      repeatType: "mirror",
    });

    return () => {
      pctControls.stop();
      mbpsControls.stop();
    };
  }, [percent, mbps, reduceMotion]);

  return (
    <div className="relative mx-auto w-full max-w-[520px]">
      <svg
        viewBox={`0 0 ${VIEW_W} ${VIEW_H}`}
        role="img"
        aria-label="Animated visualization of multi-threaded chunked downloads"
        className="h-auto w-full"
      >
        <defs>
          <linearGradient id="packetA" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#5AC8FA" />
            <stop offset="1" stopColor="#0A84FF" />
          </linearGradient>
          <linearGradient id="laneFill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#5AC8FA" stopOpacity="0.45" />
            <stop offset="1" stopColor="#0033B0" stopOpacity="0.35" />
          </linearGradient>
          <linearGradient id="arrowFill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#FFFFFF" />
            <stop offset="1" stopColor="#D8E8FF" />
          </linearGradient>
          <radialGradient id="haloGlow" cx="50%" cy="50%" r="50%">
            <stop offset="0" stopColor="#0A84FF" stopOpacity="0.5" />
            <stop offset="1" stopColor="#0A84FF" stopOpacity="0" />
          </radialGradient>
          <filter id="packetGlow" x="-100%" y="-100%" width="300%" height="300%">
            <feGaussianBlur stdDeviation="3" />
            <feMerge>
              <feMergeNode />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>

        {/* Backdrop halo behind the merge point */}
        <ellipse
          cx={VIEW_W / 2}
          cy={460}
          rx={220}
          ry={90}
          fill="url(#haloGlow)"
        />

        {/* Lanes */}
        {LANES.map((lane, i) => {
          const laneCenterX = lane.x + LANE_W / 2;
          const fillHeight = LANE_HEIGHT * lane.fillTarget;
          return (
            <g key={lane.label}>
              {/* Header label */}
              <text
                x={laneCenterX}
                y={LANE_TOP - 22}
                textAnchor="middle"
                fontFamily="var(--font-mono)"
                fontSize="11"
                fill="#8A95B8"
                letterSpacing="0.5"
              >
                {lane.label}
              </text>
              <text
                x={laneCenterX}
                y={LANE_TOP - 8}
                textAnchor="middle"
                fontFamily="var(--font-mono)"
                fontSize="11"
                fill="#D8E8FF"
                letterSpacing="0.3"
              >
                {lane.size}
              </text>

              {/* Track */}
              <rect
                x={lane.x}
                y={LANE_TOP}
                width={LANE_W}
                height={LANE_HEIGHT}
                rx={28}
                ry={28}
                fill="rgba(255,255,255,0.04)"
                stroke="rgba(216,232,255,0.10)"
              />

              {/* Animated fill (rises from bottom) */}
              <motion.rect
                x={lane.x + 1}
                width={LANE_W - 2}
                rx={27}
                ry={27}
                fill="url(#laneFill)"
                initial={{
                  y: reduceMotion ? LANE_BOTTOM - fillHeight : LANE_BOTTOM,
                  height: reduceMotion ? fillHeight : 0,
                }}
                animate={
                  reduceMotion
                    ? undefined
                    : {
                        y: [
                          LANE_BOTTOM,
                          LANE_BOTTOM - fillHeight,
                          LANE_BOTTOM - fillHeight,
                          LANE_BOTTOM,
                        ],
                        height: [0, fillHeight, fillHeight, 0],
                      }
                }
                transition={
                  reduceMotion
                    ? undefined
                    : {
                        duration: 6 + i * 0.4,
                        times: [0, 0.4, 0.85, 1],
                        ease: "easeInOut",
                        repeat: Infinity,
                        repeatType: "loop",
                        delay: i * 0.3,
                      }
                }
              />

              {/* Packets */}
              {!reduceMotion &&
                [0, 1, 2].map((j) => (
                  <motion.rect
                    key={j}
                    x={lane.x + (LANE_W - PACKET_W) / 2}
                    width={PACKET_W}
                    height={PACKET_H}
                    rx={5}
                    ry={5}
                    fill={lane.color}
                    filter="url(#packetGlow)"
                    initial={{ y: LANE_TOP - PACKET_H }}
                    animate={{
                      y: [LANE_TOP - PACKET_H, LANE_BOTTOM],
                      opacity: [0, 1, 1, 0.2],
                    }}
                    transition={{
                      y: {
                        duration: lane.duration,
                        ease: "linear",
                        repeat: Infinity,
                        repeatType: "loop",
                        delay: (j * lane.duration) / 3,
                      },
                      opacity: {
                        duration: lane.duration,
                        times: [0, 0.1, 0.85, 1],
                        ease: "linear",
                        repeat: Infinity,
                        repeatType: "loop",
                        delay: (j * lane.duration) / 3,
                      },
                    }}
                  />
                ))}

              {/* Static packets for reduced-motion */}
              {reduceMotion &&
                [0.25, 0.55, 0.78].map((t, idx) => (
                  <rect
                    key={idx}
                    x={lane.x + (LANE_W - PACKET_W) / 2}
                    y={LANE_TOP + t * LANE_HEIGHT}
                    width={PACKET_W}
                    height={PACKET_H}
                    rx={5}
                    ry={5}
                    fill={lane.color}
                  />
                ))}
            </g>
          );
        })}

        {/* Merge curves from each lane to the arrowhead apex */}
        <g stroke="rgba(90,200,250,0.35)" strokeWidth="1.5" fill="none">
          {LANES.map((lane) => {
            const startX = lane.x + LANE_W / 2;
            const startY = LANE_BOTTOM;
            const endX = VIEW_W / 2;
            const endY = 446;
            const cpX = startX;
            const cpY = (startY + endY) / 2 + 30;
            return (
              <path
                key={`curve-${lane.label}`}
                d={`M ${startX} ${startY} Q ${cpX} ${cpY} ${endX} ${endY}`}
              />
            );
          })}
        </g>

        {/* Unified arrowhead — same geometry as the app icon, scaled to viewBox */}
        <motion.g
          fill="url(#arrowFill)"
          animate={
            reduceMotion
              ? undefined
              : {
                  opacity: [0.7, 1, 0.7],
                }
          }
          transition={
            reduceMotion
              ? undefined
              : {
                  duration: 1.2,
                  ease: "easeInOut",
                  repeat: Infinity,
                  repeatType: "loop",
                }
          }
        >
          <path d="M 200 444 L 280 444 L 244 488 Q 240 494 236 488 Z" />
        </motion.g>

        {/* Readout text */}
        <text
          x={VIEW_W / 2}
          y={510}
          textAnchor="middle"
          fontFamily="var(--font-mono)"
          fontSize="13"
          fill="#D8E8FF"
          letterSpacing="0.5"
        >
          412.7 MB · {mbpsDisplay} ·{" "}
          <tspan fill="#F5F8FF" fontWeight="600">
            {percentDisplay}
          </tspan>
        </text>
      </svg>
    </div>
  );
}
