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
🧪 demo mode (tap map to place yourself).

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
