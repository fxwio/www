import { fileURLToPath } from "node:url";

await import("./install-google-font-fetch-proxy.mjs");

process.argv[1] = fileURLToPath(
  new URL("../node_modules/astro/astro.js", import.meta.url)
);

await import("../node_modules/astro/astro.js");
