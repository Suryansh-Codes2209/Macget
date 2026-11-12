// Refreshes the brand SVGs and the changelog from the MacGet app repo.
//
// This site lives in its own (private) repo, so the app repo may not be on
// disk. Sources, in order:
//   1. A local checkout: $MACGET_REPO, or ../Macget next to this repo.
//   2. The public app repo on GitHub (raw files).
//   3. Neither reachable: keep the committed copies and carry on.
// A sync failure never fails the build — the committed copies are always valid.

import { copyFile, writeFile, access } from "node:fs/promises";
import path from "node:path";

const RAW = "https://raw.githubusercontent.com/Suryansh-Codes2209/Macget/main";

const FILES = [
	{ src: "Macget/Resources/Branding/macget-icon.svg", dest: ["public/macget-icon.svg", "app/icon.svg"] },
	{ src: "Macget/Resources/Branding/macget-wordmark.svg", dest: ["public/macget-wordmark.svg"] },
	{ src: "CHANGELOG.md", dest: ["content/CHANGELOG.md"] },
];

const exists = (p) => access(p).then(() => true, () => false);

const localRepo = process.env.MACGET_REPO ?? path.resolve("..", "Macget");
const useLocal = await exists(path.join(localRepo, "CHANGELOG.md"));

for (const { src, dest } of FILES) {
	try {
		if (useLocal) {
			for (const d of dest) await copyFile(path.join(localRepo, src), d);
		} else {
			const res = await fetch(`${RAW}/${src}`, { signal: AbortSignal.timeout(10_000) });
			if (!res.ok) throw new Error(`HTTP ${res.status}`);
			const body = await res.text();
			for (const d of dest) await writeFile(d, body);
		}
		console.log(`sync-assets: ${src} (${useLocal ? "local" : "github"})`);
	} catch (err) {
		console.warn(`sync-assets: kept committed copy of ${src} (${err.message})`);
	}
}
