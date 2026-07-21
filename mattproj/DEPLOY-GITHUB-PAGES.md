# 🚀 Deploy Bebi Time on GitHub Pages (with Supabase)

This version of Bebi Time is **100% static files** — so GitHub Pages can host the whole
thing. The "backend" (accounts, friends, live location) runs on **Supabase**, a free
cloud service. You'll do two things: set up Supabase (~5 min), then publish the files
to GitHub Pages (~3 min).

You do **not** need Node, Python, or any server. Just a browser and a GitHub account.

---

## Part 1 — Set up Supabase (the backend)

### 1. Create a project
1. Go to <https://supabase.com> → **Start your project** → sign in with GitHub.
2. Click **New project**. Give it a name (e.g. `tether`), set a database password
   (save it somewhere), pick the region closest to you, and create it.
3. Wait ~2 minutes for it to finish provisioning.

### 2. Create the database + security rules
1. In your project, open the **SQL Editor** (left sidebar).
2. Click **New query**, then open the file **`supabase-schema.sql`** from this folder,
   copy **all** of it, and paste it into the editor.
3. Click **Run**. You should see "Success. No rows returned." That created every
   table, the security rules, and the app's functions.

### 3. Turn off email confirmation (so signup is instant)
By default Supabase emails a confirmation link. For a friends app that's annoying,
so switch it off:

1. Go to **Authentication** → **Sign In / Providers** (or **Providers**) → **Email**.
2. Turn **OFF** "Confirm email" (in some UIs it's **Authentication → Settings →
   "Enable email confirmations"**). Save.

> Prefer to keep confirmation on? That's fine — users just have to click the emailed
> link before their first login. The app handles both.

### 4. Copy your two keys
1. Go to **Project Settings** (gear icon) → **API** (or **Data API** + **API Keys**).
2. Copy the **Project URL** (looks like `https://abcd1234.supabase.co`).
3. Copy the **anon public** key (a long string). This one is *meant* to be public —
   your data is protected by the security rules, not by hiding this key.

### 5. Paste them into `config.js`
Open **`config.js`** in this folder and fill in the two values:

```js
window.TETHER_CONFIG = {
  SUPABASE_URL: "https://abcd1234.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOi...your-long-anon-key...",
};
```
Save the file.

---

## Part 2 — Publish to GitHub Pages

### Option A — GitHub website (no command line)
1. On <https://github.com>, click **New repository**.
   - To get the clean `https://<username>.github.io` address, name the repo **exactly**
     `<your-username>.github.io` (e.g. `matty2929.github.io`).
   - Or name it anything (e.g. `tether`) — it'll just live at
     `https://<username>.github.io/tether/` instead. Both work.
   - Make it **Public**.
2. On the new repo page → **Add file** → **Upload files**. Drag in **all the files from
   this project folder** (`index.html`, `styles.css`, `app.js`, `config.js`, and
   optionally the `.md`/`.sql`). Commit.
3. Go to **Settings** → **Pages** → under **Build and deployment**, set **Source** to
   **Deploy from a branch**, branch **main**, folder **/(root)** → **Save**.
4. Wait ~1 minute, then open your URL (shown at the top of that Pages screen). 🎉

### Option B — Command line (git)
From inside this project folder:
```bash
git init
git add .
git commit -m "Bebi Time on GitHub Pages"
git branch -M main
git remote add origin https://github.com/<username>/<username>.github.io.git
git push -u origin main
```
Then do step 3 above (Settings → Pages) if it isn't already on.

---

## Part 3 — Use it

Send your GitHub Pages link (e.g. `https://matty2929.github.io`) to your friend or
partner. On your phones:

1. Each person taps **Create account** (email + password + a display name).
2. Open the **Invite** tab to see your 6-character friend code.
3. One of you types the other's code and taps **Send** — the other taps **Accept**.
4. You now see each other live on the map, with distance, moods, and pings. ❤️

Because GitHub Pages serves over **HTTPS**, phone GPS works automatically.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Page says **"Almost there"** | `config.js` still has the placeholder values. Put in your real URL + anon key, re-upload, hard-refresh. |
| **"No one has that code."** | Codes are case-insensitive but must be exact. Make sure the friend actually created an account. |
| Signup says **check your email** | Email confirmation is still on (Part 1, step 3), or click the emailed link. |
| Friends show but **no location** | The other person must allow the browser's location prompt, or use **demo mode** (You tab → tap map). GPS needs the HTTPS Pages URL, not a local file. |
| **"permission denied for..."** in console | Re-run `supabase-schema.sql` — the grants at the bottom must succeed. |
| Nothing loads / blank | Check the browser console (F12). Confirm the Supabase URL/key are correct and the project isn't paused (free projects pause after long inactivity — open the Supabase dashboard to wake it). |

## Is my data safe?
- Passwords are handled by Supabase Auth (hashed, never stored by us).
- The **Row Level Security** rules in `supabase-schema.sql` mean a person can only ever
  read their **own** data and the data of friends they've **accepted** — even though the
  anon key is public. Nobody can list all users or see a stranger's location.
- Location is sensitive: only share this link with people you trust, and remember anyone
  with an accepted friendship can see your live position while you're sharing.
