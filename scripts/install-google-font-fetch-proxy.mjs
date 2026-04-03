import { ProxyAgent, fetch as proxyFetch } from "undici";

const GOOGLE_FONT_HOSTS = new Set([
  "fonts.google.com",
  "fonts.googleapis.com",
  "fonts.gstatic.com",
]);

const INSTALL_FLAG = Symbol.for("vigorous-venus.google-font-fetch-proxy");

if (!globalThis[INSTALL_FLAG]) {
  const proxyUrl = resolveProxyUrl();

  if (proxyUrl) {
    const agent = new ProxyAgent(proxyUrl);
    const nativeFetch = globalThis.fetch.bind(globalThis);

    globalThis.fetch = (input, init) => {
      const url = resolveRequestUrl(input);

      if (!url || !GOOGLE_FONT_HOSTS.has(url.hostname)) {
        return nativeFetch(input, init);
      }

      return proxyFetch(input, {
        ...init,
        dispatcher: agent,
      });
    };
  }

  globalThis[INSTALL_FLAG] = true;
}

function resolveProxyUrl() {
  const candidates = [
    process.env.HTTPS_PROXY,
    process.env.https_proxy,
    process.env.HTTP_PROXY,
    process.env.http_proxy,
    process.env.ALL_PROXY,
    process.env.all_proxy,
  ].filter(Boolean);

  for (const candidate of candidates) {
    try {
      const url = new URL(candidate);

      if (url.protocol === "http:" || url.protocol === "https:") {
        return url.toString();
      }
    } catch {
      // Ignore malformed proxy env vars and keep scanning.
    }
  }

  return null;
}

function resolveRequestUrl(input) {
  try {
    if (input instanceof Request) {
      return new URL(input.url);
    }

    return new URL(input);
  } catch {
    return null;
  }
}
