const CACHE_NAME = "vineyard-maps-v5";

// Only cache your app shell (NOT Google Maps tiles/scripts, NOT customer data).
// Every path here MUST exist on disk, or cache.addAll() rejects and the SW never installs.
const APP_ASSETS = [
  "/",
  "/index.html",
  "/manifest.webmanifest",
  "/images/SWAT_Logo_june2025.png",
  "/icons/icon-192.png",
  "/icons/icon-512.png"
];

// Install: pre-cache core assets
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_ASSETS))
  );
  self.skipWaiting();
});

// Activate: clean old caches
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.map((k) => (k === CACHE_NAME ? null : caches.delete(k))))
    )
  );
  self.clients.claim();
});

// Fetch: network-first for same-origin requests (so updates appear)
// If offline, fall back to cache.
self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);

  // Only handle requests to your own origin
  if (url.origin !== self.location.origin) return;

  event.respondWith(
    fetch(event.request)
      .then((resp) => {
        // Update cache in the background for GETs
        if (event.request.method === "GET") {
          const copy = resp.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
        }
        return resp;
      })
      .catch(() => caches.match(event.request).then((c) => c || caches.match("/")))
  );
});
