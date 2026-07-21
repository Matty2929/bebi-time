# 🚀 Deploy Bebi Time on Vercel (with Supabase)

Vercel hosts the static app (over HTTPS, so phone GPS works); Supabase is the
backend (accounts, friends, live location). Total time ≈ 10 minutes, no coding.

There are two parts: **set up Supabase once**, then **publish to Vercel**.

---

## Part 1 — Set up Supabase (the backend)

*(Skip this if you already did it for the GitHub Pages guide — it's the same.)*

1. **Create a project** — <https://supabase.com> → sign in → **New project**. Set a
   database password, pick a nearby region, create it, wait ~2 min.
2. **Create the database** — open **SQL Editor** → **New query** → paste **all** of
   [`supabase-schema.sql`](supabase-schema.sql) → **Run**. This makes every table,
   the security rules, the app's functions, and enables **instant live updates**
   (Realtime). Already ran an older version? Just run it again — it's safe to re-run.
3. **Instant signup** — **Authentication → Sign In / Providers → Email** → turn **OFF**
   "Confirm email" (or **Authentication → Settings → Enable email confirmations**). Save.
4. **Copy your keys** — **Project Settings → API** (or **Data API** + **API Keys**):
   - **Project URL** → e.g. `https://abcd1234.supabase.co`
   - **anon public** key → the long string (safe to publish — RLS protects your data)
5. **Paste into [`config.js`](config.js):**
   ```js
   window.TETHER_CONFIG = {
     SUPABASE_URL: "https://abcd1234.supabase.co",
     SUPABASE_ANON_KEY: "eyJhbGciOi...your-anon-key...",
   };
   ```
   Save.

---

## Part 2 — Publish to Vercel

Vercel deploys straight from a GitHub repo — no Node or CLI needed on your PC (which
is good, since you don't have Node installed).

### Step 1 — Put the app on GitHub
Create a repo and upload **the contents of this project folder**
(`index.html`, `styles.css`, `app.js`, `config.js`, `vercel.json`, and optionally the
`.sql`/`.md` files).

- **No command line:** github.com → **New repository** (Public) → **Add file → Upload
  files** → drag them all in → **Commit**.
- **With git:**
  ```bash
  cd mattproj
  git init && git add . && git commit -m "Bebi Time"
  git branch -M main
  git remote add origin https://github.com/<username>/<repo>.git
  git push -u origin main
  ```

### Step 2 — Import into Vercel
1. Go to <https://vercel.com/new> (sign in with GitHub).
2. **Import** the repo you just created.
3. On the configure screen:
   - **Framework Preset:** **Other** (it's a plain static site — no build step).
   - **Build Command:** leave empty.
   - **Output Directory:** leave as default (`.`).
   - **Root Directory:** if your repo has the files at the top level, leave it blank.
     If you committed the whole project and the app is inside a subfolder,
     click **Edit** and set Root Directory to that subfolder.
4. Click **Deploy**. In ~30 seconds you get a live URL like
   `https://tether-xxxx.vercel.app`. 🎉

That's it — every future `git push` (or file edit on GitHub) auto-redeploys.

### Step 3 — (Optional) point Supabase at your Vercel URL
Only needed if you kept email confirmation **on**: in Supabase → **Authentication →
URL Configuration**, set **Site URL** to your `https://…vercel.app` address so
confirmation links come back to your app. With confirmation off, you can skip this.

---

## Part 3 — Use it
Send your Vercel link to your friend or partner. Each person:
1. Taps **Create account** (email + password + display name).
2. Opens **Invite** to see their 6-char friend code.
3. One types the other's code → **Send**; the other taps **Accept**.
4. You're now live on each other's map — distance, moods, pings and all. ❤️

---

## Vercel vs. GitHub Pages — which should I use?
Both are free and both work. Use whichever you prefer:

| | Vercel | GitHub Pages |
|---|---|---|
| Custom domains | ✅ easy | ✅ |
| Auto-deploy on push | ✅ | ✅ |
| Deploy previews per branch | ✅ | ❌ |
| Setup | Import repo | Enable Pages in settings |

If you've got Vercel, just use Vercel — the [`vercel.json`](vercel.json) in this folder
is already configured for it.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Page says **"Almost there"** | `config.js` still has placeholders. Fix it, push again (Vercel redeploys), hard-refresh. |
| Deploy succeeds but page is **blank / 404** | Wrong **Root Directory** in Vercel — set it to the folder that contains `index.html`. |
| Signup says **check your email** | Email confirmation is still on (Part 1, step 3). |
| Friends show but **no location** | The other person must allow the location prompt, or use demo mode (You tab → tap map). |
| **"permission denied for…"** in console (F12) | Re-run `supabase-schema.sql`; the grants at the bottom must succeed. |
| Blank after a while | Free Supabase projects pause after long inactivity — open the Supabase dashboard to wake it. |

## Safety
Passwords are managed by Supabase Auth (hashed). The Row Level Security rules in
`supabase-schema.sql` ensure each person can only read their own data and the data of
friends they've accepted — even though the anon key in `config.js` is public. Only share
your link with people you trust; live location is sensitive.
