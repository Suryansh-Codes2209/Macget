import nextCoreWebVitals from "eslint-config-next/core-web-vitals";
import nextTypescript from "eslint-config-next/typescript";

// Flat config. Next 16 removed `next lint`, so linting runs through the ESLint
// CLI directly (`bun run lint`).
const config = [
  {
    ignores: [
      ".next/**",
      "node_modules/**",
      "next-env.d.ts",
      "public/**",
      ".source/**",
    ],
  },
  ...nextCoreWebVitals,
  ...nextTypescript,
];

export default config;
