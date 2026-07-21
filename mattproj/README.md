# 🧭 Bebi Time (GitHub Pages + Supabase edition)

A fully **static** build of Bebi Time — a live location-sharing app for friends &
couples. Because there's no server code, you can host the entire thing on
**GitHub Pages** for free. Accounts, friendships, and live location are handled by
**Supabase** (also free).

**➡️ Get it live — pick your host:**
- **[DEPLOY-VERCEL.md](DEPLOY-VERCEL.md)** — deploy on Vercel (recommended if you have it)
- **[DEPLOY-GITHUB-PAGES.md](DEPLOY-GITHUB-PAGES.md)** — deploy on GitHub Pages

Both are free and use the same Supabase backend.

## Files
| File | What it is |
|------|------------|
| `index.html` | The app shell |
| `styles.css` | Dark, mobile-first styling |
| `app.js` | All the client logic (talks to Supabase) |
| `config.js` | **You edit this** — your Supabase URL + anon key |
| `supabase-schema.sql` | Run once in Supabase to create the database + security rules |
| `vercel.json` | Vercel hosting config (static site, sensible cache headers) |
| `DEPLOY-VERCEL.md` | Step-by-step Vercel deployment guide |
| `DEPLOY-GITHUB-PAGES.md` | Step-by-step GitHub Pages deployment guide |

## Features
🔐 Email/password accounts · 🎟️ shareable friend codes · 🤝 invite & accept ·
🗺️ live map with distance, presence & battery · 😊 moods/status · 👋❤️🫂 pings ·
🐣 shared virtual pet you care for together · 💬 chat · 📲 installable PWA (offline shell) ·
🧪 demo mode (tap map to place yourself).

### 📲 Install as an app (PWA)
Bebi Time is a Progressive Web App: on any HTTPS host (GitHub Pages / Vercel) or on
`localhost`, your browser will offer **“Add to Home Screen” / “Install”**. It then
launches full-screen with its own icon, and the app shell is cached so it opens
instantly even on a flaky connection. (Live location & realtime still need a network.)
Files: `manifest.json`, `service-worker.js`, `icons/`. Bump the `CACHE` version in
`service-worker.js` whenever you change shell files, to push the update to installed apps.

### 🐣 Shared pet
Each pair of friends (your 💗 partner or any friend) can **hatch one shared pet** and
raise it together from the **Pet** tab. Feed 🍎 / play 🎾 / clean 🛁 / cuddle ❤️ — either
person’s care syncs instantly to the other via Supabase Realtime. Stats slowly decay over
real time (computed on read, so no background job is needed) and the pet earns XP/levels.
Backed by the `pets` table + `get_pet` / `pet_action` / `set_pet` functions.

### 🔥 Together streak
Each shared pet also tracks a **together streak** — the number of consecutive days you
*both* showed up. It advances inside `get_state` whenever both members of a pair have
opened the app on the same day (guarded so each pet is written at most once per person
per day — no realtime feedback loop), and it shows as a 🔥 badge on the pet card. Miss a
day and it resets. (Days are counted in the database’s UTC calendar.)

### 🔔 Pet care reminders (notifications)
Toggle **“Pet care reminders”** in the **You** tab. When a shared pet’s hunger/fun/clean
drops low, Bebi Time raises a notification through the service worker — one nudge per pet
that re-arms once the pet recovers. This works while the app is open or installed and
running in the background. For reminders when the app is **fully closed**, you’d add
server-sent **Web Push** (a Supabase Edge Function on a schedule + VAPID keys); the service
worker already includes the `push` handler for that — ask and it can be scaffolded.

> **After updating:** re-run **`supabase-schema.sql`** in your Supabase SQL Editor once
> to create the `pets` table, its security rules, and the pet functions. It’s safe to
> re-run — everything is `create … if not exists` / `create or replace`.

## How the pieces fit
```
 Phone browser ──HTTPS──► GitHub Pages (static files: html/css/js)
      │
      └──────────────────► Supabase  (Auth + Postgres + Row Level Security)
                            • accounts & sessions
                            • profiles / friendships / locations / pings
                            • get_state(), send_friend_request(), … RPC functions
```
Security lives in the database: the Row Level Security policies in
`supabase-schema.sql` ensure each person can only read their own data and the data
of friends they've accepted — even though the anon key in `config.js` is public.

## Note
This is the static/Supabase edition. The repo also contains a self-hosted Python
edition (`../tether`) if you'd rather run your own server.
