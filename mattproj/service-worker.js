/* Bebi Time service worker — offline app shell + fast launches.
   Bump CACHE whenever you change shell files to force an update. */
const CACHE = "bebi-v3";

// Same-origin files that make up the app shell.
const SHELL = [
  "./",
  "./index.html",
  "./styles.css",
  "./app.js",
  "./config.js",
  "./manifest.json",
  "./logo.svg",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/apple-touch-icon.png",
];

self.addEventListener("install", (e) => {
  e.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// Tapping a pet-care reminder should focus the app (or open it if it's closed).
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "./";
  e.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if ("focus" in c) { c.focus(); return; }
      }
      if (self.clients.openWindow) return self.clients.openWindow(url);
    })
  );
});

// Web Push handler — used if you later add server-sent pushes (see README).
// Harmless to keep now; it only runs when a real push message arrives.
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data && e.data.text() }; }
  e.waitUntil(
    self.registration.showNotification(d.title || "Bebi Time 🐾", {
      body: d.body || "Your pet needs some care 💗",
      icon: "icons/icon-192.png",
      badge: "icons/icon-192.png",
      tag: d.tag || "bebi-push",
      data: d.data || { url: "./" },
    })
  );
});

// CDN library hosts we're happy to cache (Leaflet, Supabase JS).
const CDN_LIBS = ["unpkg.com", "cdn.jsdelivr.net"];

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return; // never touch writes

  const url = new URL(req.url);

  // Supabase (auth, data, realtime) must always hit the network — never cache.
  if (url.hostname.endsWith(".supabase.co") || url.hostname.endsWith(".supabase.in")) return;

  // Map tiles: straight to network, don't fill the cache with thousands of tiles.
  if (url.hostname.includes("cartocdn.com")) return;

  // Page navigations: network-first (fresh app), fall back to cached shell offline.
  if (req.mode === "navigate") {
    e.respondWith(
      fetch(req).catch(() => caches.match("./index.html").then((c) => c || Response.error()))
    );
    return;
  }

  // Our own HTML/CSS/JS/icons: network-first so edits are picked up immediately when
  // online; fall back to the cached copy only when offline. (Keeps a fresh copy cached.)
  if (url.origin === location.origin) {
    e.respondWith(
      fetch(req)
        .then((res) => {
          if (res.ok) {
            const copy = res.clone();
            caches.open(CACHE).then((c) => c.put(req, copy));
          }
          return res;
        })
        .catch(() => caches.match(req))
    );
    return;
  }

  // CDN libraries (Leaflet, Supabase JS) are versioned & stable: cache-first.
  if (CDN_LIBS.includes(url.hostname)) {
    e.respondWith(
      caches.match(req).then((cached) => {
        if (cached) return cached;
        return fetch(req).then((res) => {
          if (res.ok && res.type !== "opaque") {
            const copy = res.clone();
            caches.open(CACHE).then((c) => c.put(req, copy));
          }
          return res;
        });
      })
    );
    return;
  }
  // Anything else: just go to the network.
});
