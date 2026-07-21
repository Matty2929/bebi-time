/* Bebi Time frontend — vanilla JS + Leaflet + Supabase (fully static, GitHub-Pages ready) */

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

const AVATARS = ["🦊","🐼","🐨","🐯","🦁","🐸","🐵","🦉","🐧","🦄","🐙","🌸","⭐","🔥","🌊","🍀","🐺","🦈"];
const PET_SPECIES = ["🐣","🐥","🐤","🐰","🐱","🐶","🐼","🐨","🦊","🐸","🐧","🐢","🦄","🐹","🐷","🐙","🦖","🐳"];

/* ---------------- Supabase client ---------------- */
const cfg = window.BEBI_CONFIG || {};
const configured =
  cfg.SUPABASE_URL &&
  cfg.SUPABASE_ANON_KEY &&
  !cfg.SUPABASE_URL.includes("YOUR-PROJECT") &&
  !cfg.SUPABASE_ANON_KEY.includes("YOUR-ANON");

let sb = null;
if (configured) {
  sb = supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);
}

/* ---------------- App state ---------------- */
let me = null;
let uid = null;
let map = null;
let markers = {};       // userId(uuid) -> L.marker
let myMarker = null;
let manualMode = false;
let sharing = true;
let pollTimer = null;
let followMe = true;
let geoWatch = null;
let rtChannel = null;       // Supabase Realtime channel
let currentFriends = [];    // last-known friends list (kept in sync for realtime)
let friendsById = {};       // uuid -> friend object
let myLatLng = null;        // my last position, for live distance math
let petsById = {};          // petId -> pet object (pets I own or co-parent)
let petSelectedId = null;   // which pet the Pet tab is showing
let petInvitesList = [];    // incoming "co-parent my pet?" requests

/* ---------------- Small helpers ---------------- */
async function rpc(fn, args) {
  const { data, error } = await sb.rpc(fn, args || {});
  if (error) throw new Error(error.message);
  return data;
}

/* ---------------- Auth screen wiring ---------------- */
$$(".tab").forEach((t) =>
  t.addEventListener("click", () => {
    $$(".tab").forEach((x) => x.classList.remove("active"));
    t.classList.add("active");
    const tab = t.dataset.tab;
    $("#login-form").classList.toggle("hidden", tab !== "login");
    $("#register-form").classList.toggle("hidden", tab !== "register");
    $("#auth-error").textContent = "";
  })
);

$("#login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = e.target;
  $("#auth-error").textContent = "";
  try {
    const { data, error } = await sb.auth.signInWithPassword({
      email: f.email.value.trim(),
      password: f.password.value,
    });
    if (error) throw error;
    uid = data.user.id;
    enterApp();
  } catch (err) {
    $("#auth-error").textContent = friendlyAuthError(err);
  }
});

$("#register-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = e.target;
  $("#auth-error").textContent = "";
  try {
    const { data, error } = await sb.auth.signUp({
      email: f.email.value.trim(),
      password: f.password.value,
      options: { data: { display_name: f.displayName.value.trim() || "Friend" } },
    });
    if (error) throw error;
    if (data.session) {
      uid = data.user.id;
      enterApp();
    } else {
      // Email confirmation is still enabled on the Supabase project.
      $("#auth-error").style.color = "var(--muted)";
      $("#auth-error").textContent =
        "Account created! Check your email to confirm, then log in. (Tip: disable 'Confirm email' in Supabase to skip this.)";
      $('.tab[data-tab="login"]').click();
    }
  } catch (err) {
    $("#auth-error").style.color = "";
    $("#auth-error").textContent = friendlyAuthError(err);
  }
});

function friendlyAuthError(err) {
  const m = (err && err.message) || String(err);
  if (/already registered/i.test(m)) return "That email already has an account — try logging in.";
  if (/invalid login/i.test(m)) return "Wrong email or password.";
  if (/at least 6/i.test(m) || /password/i.test(m)) return "Password must be at least 6 characters.";
  if (/confirm/i.test(m)) return "Please confirm your email first (check your inbox).";
  return m;
}

/* ---------------- Enter / leave app ---------------- */
function enterApp() {
  $("#setup-warning").classList.add("hidden");
  $("#auth").classList.add("hidden");
  $("#app").classList.remove("hidden");
  if (!map) initMap();
  buildAvatarPicker();
  $("#pet-notify-toggle").checked =
    petNotifyEnabled() && "Notification" in window && Notification.permission === "granted";
  startLocation();
  poll();
  subscribeRealtime();
  // Realtime pushes location changes instantly; this slow poll is just a safety
  // net that also refreshes presence, requests and the friend list.
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = setInterval(poll, 12000);
  setTimeout(() => map.invalidateSize(), 200);
}

/* ---------------- Realtime (instant updates) ---------------- */
function subscribeRealtime() {
  if (!sb) return;
  if (rtChannel) { sb.removeChannel(rtChannel); rtChannel = null; }
  rtChannel = sb
    .channel("bebi-realtime")
    // Friends' live location — RLS ensures we only receive our own + friends' rows.
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "locations" },
      (payload) => {
        const row = payload.new;
        if (row && row.user_id && row.user_id !== uid) onFriendLocation(row);
      }
    )
    // Someone pinged me — refresh to fetch + show it.
    .on(
      "postgres_changes",
      { event: "INSERT", schema: "public", table: "pings", filter: `to_id=eq.${uid}` },
      () => poll()
    )
    // A friend request arrived/changed — refresh the requests panel.
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "friend_requests", filter: `to_id=eq.${uid}` },
      () => poll()
    )
    // A new message to me — drop it into the open chat or badge + toast it.
    .on(
      "postgres_changes",
      { event: "INSERT", schema: "public", table: "messages", filter: `to_id=eq.${uid}` },
      (payload) => onIncomingMessage(payload.new)
    )
    // A pet I care for changed (co-parent fed/played/cleaned it) — refresh.
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "pets" },
      () => poll()
    )
    // A co-parent request addressed to me arrived/changed — refresh.
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "pet_invites", filter: `to_id=eq.${uid}` },
      () => poll()
    )
    .subscribe();
}

function onIncomingMessage(m) {
  if (!m) return;
  if (chatFriendId && m.from_id === chatFriendId && !$("#chat-modal").classList.contains("hidden")) {
    appendMessage(m);
    sb.from("messages").update({ read: true }).eq("id", m.id).then(() => {});
  } else {
    const f = friendById(m.from_id);
    toast(`💬 ${f ? friendLabel(f) : "New message"}: ${escapeHtml(m.body.slice(0, 40))}`, 3500);
    poll(); // refresh unread badges
  }
}

function onFriendLocation(row) {
  const f = friendsById[row.user_id];
  if (!f) { poll(); return; } // a brand-new friend we don't have cached yet
  f.location = {
    lat: row.lat, lng: row.lng, accuracy: row.accuracy,
    battery: row.battery, updatedAt: Date.now() / 1000,
  };
  f.online = true;
  f.lastSeen = Date.now() / 1000;
  if (myLatLng) f.distance = Math.round(haversineJS(myLatLng.lat, myLatLng.lng, row.lat, row.lng));
  updateFriendMarkers(currentFriends);
  renderFriends(currentFriends);
  updateDuoBanner(currentFriends);
}

/* ---------------- Map ---------------- */
function initMap() {
  map = L.map("map", { zoomControl: false, attributionControl: true }).setView([20, 0], 2);
  L.tileLayer("https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png", {
    attribution: "&copy; OpenStreetMap &copy; CARTO",
    maxZoom: 20,
  }).addTo(map);

  map.on("dragstart", () => (followMe = false));
  map.on("click", (e) => {
    if (manualMode) {
      setMyLocation(e.latlng.lat, e.latlng.lng, 0);
      manualMode = false;
      $("#manual-loc").textContent = "Set location by tapping map (demo)";
      toast("📍 Location set");
    }
  });
}

function avatarIcon(emoji, cls = "") {
  return L.divIcon({
    className: "",
    html: `<div class="map-avatar ${cls}"><span>${emoji}</span></div>`,
    iconSize: [44, 44],
    iconAnchor: [22, 44],
    popupAnchor: [0, -44],
  });
}

/* ---------------- Location ---------------- */
function startLocation() {
  if (!sharing) return;
  if (!("geolocation" in navigator)) {
    $("#loc-hint").textContent = "No GPS available — use demo mode below.";
    return;
  }
  if (geoWatch) navigator.geolocation.clearWatch(geoWatch);
  geoWatch = navigator.geolocation.watchPosition(
    (pos) => {
      const { latitude, longitude, accuracy } = pos.coords;
      setMyLocation(latitude, longitude, accuracy);
      $("#loc-hint").textContent = "Live GPS · accuracy ±" + Math.round(accuracy) + "m";
    },
    (err) => {
      $("#loc-hint").textContent =
        "GPS blocked (" + err.message + "). Tap the map in demo mode instead.";
    },
    { enableHighAccuracy: true, maximumAge: 5000, timeout: 15000 }
  );
}

async function setMyLocation(lat, lng, accuracy) {
  let battery = null;
  try {
    if (navigator.getBattery) {
      const b = await navigator.getBattery();
      battery = Math.round(b.level * 100);
    }
  } catch (_) {}
  try {
    const { error } = await sb.from("locations").upsert({
      user_id: uid,
      lat,
      lng,
      accuracy: accuracy || 0,
      battery,
      updated_at: new Date().toISOString(),
    });
    if (error) throw error;
    myLatLng = { lat, lng };
    placeMyMarker(lat, lng);
    $("#me-status").textContent = me?.mood || "Sharing live · you";
  } catch (err) {
    console.warn("location upsert failed:", err.message);
  }
}

function placeMyMarker(lat, lng) {
  const icon = avatarIcon(me?.avatar || "🦊", "me");
  if (!myMarker) {
    myMarker = L.marker([lat, lng], { icon, zIndexOffset: 1000 }).addTo(map);
    myMarker.bindPopup("You");
  } else {
    myMarker.setIcon(icon);
    myMarker.setLatLng([lat, lng]);
  }
  if (followMe) map.setView([lat, lng], Math.max(map.getZoom(), 15), { animate: true });
}

/* ---------------- Poll + render ---------------- */
async function poll() {
  try {
    const state = await rpc("get_state");
    me = state.me;
    currentFriends = state.friends || [];
    friendsById = {};
    currentFriends.forEach((f) => (friendsById[f.id] = f));
    if (state.myLocation) myLatLng = state.myLocation;
    petsById = {};
    (state.pets || []).forEach((pt) => (petsById[pt.id] = pt));
    petInvitesList = state.petInvites || [];
    renderMe();
    renderFriends(currentFriends);
    renderRequests(state.requests || []);
    updateFriendMarkers(currentFriends);
    updateDuoBanner(currentFriends);
    renderPet();
    updatePetAlert();
    maybePetNotify();
    (state.pings || []).forEach(showPing);
  } catch (err) {
    if (/not authenticated|jwt|token/i.test(err.message)) logout();
    else console.warn("poll error:", err.message);
  }
}

function renderMe() {
  if (!me) return;
  $("#me-avatar").textContent = me.avatar;
  $("#me-name").textContent = me.displayName;
  $("#my-code").textContent = me.friendCode;
  if (me.mood) $("#me-status").textContent = me.mood;
}

function renderFriends(friends) {
  $("#friend-count").textContent = friends.length;
  const list = $("#friend-list");
  $("#friends-empty").classList.toggle("hidden", friends.length > 0);
  list.innerHTML = "";
  friends
    .slice()
    .sort((a, b) => (b.partner - a.partner) || (b.online - a.online))
    .forEach((f) => {
      const li = document.createElement("li");
      li.className = "friend-item";
      const dist = f.distance != null ? fmtDist(f.distance) : "";
      const seen = f.online ? "Online now" : "Last seen " + fmtAgo(f.lastSeen);
      const sub = f.note || f.mood || (f.location ? seen : "No location yet");
      const nickTag = f.nickname ? `<span class="nick-tag">(${escapeHtml(f.displayName)})</span>` : "";
      const label = escapeHtml(friendLabel(f));
      li.innerHTML = `
        <div class="avatar">${f.avatar}<span class="dot ${f.online ? "online" : ""}"></span></div>
        <div class="friend-info">
          <div class="name">${f.partner ? '<span class="heart-badge">💗</span> ' : ""}${label} ${nickTag} ${f.mood ? `<span>${escapeHtml(f.mood)}</span>` : ""}</div>
          <div class="sub">${escapeHtml(sub)}</div>
        </div>
        <div class="friend-meta">
          ${dist ? `<div>${dist}</div>` : ""}
          ${f.location && f.location.battery != null ? `<div>🔋${f.location.battery}%</div>` : ""}
        </div>
        <div class="friend-actions">
          ${f.unread ? `<span class="unread-pill">${f.unread}</span>` : ""}
          <button class="mini-btn" data-act="chat" title="Message">💬</button>
        </div>`;
      li.querySelector('[data-act="chat"]').addEventListener("click", (e) => {
        e.stopPropagation();
        openChat(f);
      });
      li.addEventListener("click", () => openProfile(f));
      list.appendChild(li);
    });
}

/* Display name for a friend = your private nickname if set, else their name. */
function friendLabel(f) {
  return (f && (f.nickname || f.displayName)) || "Friend";
}
function friendById(id) {
  return friendsById[id] || currentFriends.find((f) => f.id === id) || null;
}

/* ---------------- Couple-themed "love" pings ---------------- */
const LOVE_KINDS = [
  { kind: "kiss", emoji: "😘", label: "Kiss" },
  { kind: "love", emoji: "❤️", label: "Love you" },
  { kind: "hug", emoji: "🫂", label: "Hug" },
  { kind: "miss", emoji: "🥺", label: "Miss you" },
  { kind: "thinking", emoji: "💭", label: "Thinking of you" },
  { kind: "omw", emoji: "🚗", label: "On my way" },
];

/* ---------------- Friend / partner profile ---------------- */
let profileFriendId = null;

function openProfile(f) {
  profileFriendId = f.id;
  $("#pf-avatar").textContent = f.avatar;
  $("#pf-name").textContent = friendLabel(f);
  $("#pf-status").textContent = f.online ? "🟢 Online now" : "Last seen " + fmtAgo(f.lastSeen);
  $("#pf-nickname").value = f.nickname || "";
  $("#pf-partner-toggle").checked = !!f.partner;
  $("#pf-since").value = f.since || "";
  $("#pf-since-wrap").classList.toggle("hidden", !f.partner);

  // partner badge + together counter
  $("#pf-partner-badge").classList.toggle("hidden", !f.partner);
  const together = $("#pf-together");
  if (f.partner && f.since) {
    const days = Math.max(0, Math.floor((Date.now() - new Date(f.since).getTime()) / 86400000));
    together.textContent = `💗 Together for ${days.toLocaleString()} day${days === 1 ? "" : "s"}`;
    together.classList.remove("hidden");
  } else {
    together.classList.add("hidden");
  }

  // love ping grid
  const grid = $("#pf-love");
  grid.innerHTML = "";
  LOVE_KINDS.forEach((lk) => {
    const b = document.createElement("button");
    b.className = "love-btn";
    b.innerHTML = `<span class="emoji">${lk.emoji}</span>${lk.label}`;
    b.addEventListener("click", async () => {
      try {
        await rpc("send_ping", { friend_id: f.id, kind: lk.kind });
        toast(`${lk.emoji} Sent to ${friendLabel(f)}`);
      } catch (e) { toast("⚠️ " + e.message); }
    });
    grid.appendChild(b);
  });

  $("#profile-modal").classList.remove("hidden");
}

function closeProfile() {
  $("#profile-modal").classList.add("hidden");
  profileFriendId = null;
}

$("#profile-close").addEventListener("click", closeProfile);
$("#profile-modal").addEventListener("click", (e) => {
  if (e.target.id === "profile-modal") closeProfile();
});

$("#pf-locate").addEventListener("click", () => {
  const f = friendById(profileFriendId);
  if (f && f.location) {
    followMe = false;
    closeProfile();
    collapseSheet();
    map.setView([f.location.lat, f.location.lng], 16, { animate: true });
    markers[f.id]?.openPopup();
  } else toast("They haven't shared a location yet");
});

$("#pf-message").addEventListener("click", () => {
  const f = friendById(profileFriendId);
  if (f) openChat(f);
});

$("#pf-nickname-save").addEventListener("click", async () => {
  const f = friendById(profileFriendId);
  if (!f) return;
  try {
    await rpc("set_friend_nickname", { friend_id: f.id, nickname: $("#pf-nickname").value.trim() });
    toast("Nickname saved ✓");
    await poll();
    const nf = friendById(f.id);
    if (nf) { nf.nickname = $("#pf-nickname").value.trim(); $("#pf-name").textContent = friendLabel(nf); }
  } catch (e) { toast("⚠️ " + e.message); }
});

$("#pf-partner-toggle").addEventListener("change", async (e) => {
  const f = friendById(profileFriendId);
  if (!f) return;
  const isPartner = e.target.checked;
  $("#pf-since-wrap").classList.toggle("hidden", !isPartner);
  try {
    await rpc("set_partner", {
      friend_id: f.id, is_partner: isPartner, since_date: $("#pf-since").value || null,
    });
    toast(isPartner ? "💗 Set as your partner" : "Removed partner");
    await poll();
  } catch (err) { toast("⚠️ " + err.message); }
});

$("#pf-since").addEventListener("change", async () => {
  const f = friendById(profileFriendId);
  if (!f || !$("#pf-partner-toggle").checked) return;
  try {
    await rpc("set_partner", {
      friend_id: f.id, is_partner: true, since_date: $("#pf-since").value || null,
    });
    toast("Anniversary saved 💗");
    await poll();
    openProfile(friendById(f.id) || f);
  } catch (e) { toast("⚠️ " + e.message); }
});

$("#pf-remove").addEventListener("click", () => {
  const f = friendById(profileFriendId);
  if (!f) return;
  if (confirm("Remove " + friendLabel(f) + "?")) {
    rpc("remove_friend", { friend_id: f.id })
      .then(() => { closeProfile(); poll(); })
      .catch((e) => toast("⚠️ " + e.message));
  }
});

/* ---------------- Chat ---------------- */
let chatFriendId = null;

async function openChat(f) {
  chatFriendId = f.id;
  closeProfile();
  $("#chat-avatar").textContent = f.avatar;
  $("#chat-name").textContent = friendLabel(f);
  $("#chat-log").innerHTML = '<div class="chat-empty">Loading…</div>';
  $("#chat-modal").classList.remove("hidden");
  await loadMessages(f.id);
  $("#chat-text").focus();
}

function closeChat() {
  $("#chat-modal").classList.add("hidden");
  chatFriendId = null;
}

async function loadMessages(fid) {
  try {
    const { data, error } = await sb
      .from("messages")
      .select("*")
      .or(`and(from_id.eq.${uid},to_id.eq.${fid}),and(from_id.eq.${fid},to_id.eq.${uid})`)
      .order("created_at", { ascending: true })
      .limit(300);
    if (error) throw error;
    renderMessages(data || []);
    // mark their messages to me as read, then refresh unread badges
    await sb.from("messages").update({ read: true })
      .eq("from_id", fid).eq("to_id", uid).eq("read", false);
    poll();
  } catch (e) {
    $("#chat-log").innerHTML = `<div class="chat-empty">⚠️ ${escapeHtml(e.message)}</div>`;
  }
}

function renderMessages(msgs) {
  const log = $("#chat-log");
  if (!msgs.length) { log.innerHTML = '<div class="chat-empty">Say hi 👋💕</div>'; return; }
  log.innerHTML = "";
  msgs.forEach((m) => appendMessage(m, false));
  log.scrollTop = log.scrollHeight;
}

function appendMessage(m, scroll = true) {
  const log = $("#chat-log");
  const empty = log.querySelector(".chat-empty");
  if (empty) empty.remove();
  const div = document.createElement("div");
  div.className = "msg " + (m.from_id === uid ? "me" : "them");
  div.innerHTML = `${escapeHtml(m.body)}<span class="time">${fmtTime(m.created_at)}</span>`;
  log.appendChild(div);
  if (scroll) log.scrollTop = log.scrollHeight;
}

$("#chat-close").addEventListener("click", closeChat);
$("#chat-locate").addEventListener("click", () => {
  const f = friendById(chatFriendId);
  if (f && f.location) {
    followMe = false; closeChat(); collapseSheet();
    map.setView([f.location.lat, f.location.lng], 16, { animate: true });
    markers[f.id]?.openPopup();
  } else toast("They haven't shared a location yet");
});
$("#chat-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("#chat-text");
  const body = input.value.trim();
  if (!body || !chatFriendId) return;
  input.value = "";
  try {
    const { data, error } = await sb
      .from("messages")
      .insert({ from_id: uid, to_id: chatFriendId, body })
      .select()
      .single();
    if (error) throw error;
    appendMessage(data);
  } catch (err) {
    toast("⚠️ " + err.message);
    input.value = body;
  }
});

function renderRequests(requests) {
  const badge = $("#req-count");
  badge.textContent = requests.length || "";
  badge.dataset.zero = requests.length === 0;
  const list = $("#request-list");
  $("#requests-empty").classList.toggle("hidden", requests.length > 0);
  list.innerHTML = "";
  requests.forEach((r) => {
    const li = document.createElement("li");
    li.className = "request-item";
    li.innerHTML = `
      <span class="avatar">${r.avatar}</span>
      <span class="name">${escapeHtml(r.displayName)} <small class="muted">${escapeHtml(r.code || "")}</small></span>
      <button class="btn primary small" data-a="accept">Accept</button>
      <button class="btn ghost small" data-a="decline">✕</button>`;
    li.querySelector('[data-a="accept"]').addEventListener("click", async () => {
      try {
        await rpc("respond_friend_request", { request_id: r.id, accept: true });
        toast("🤝 You're now friends!");
        poll();
      } catch (e) { toast("⚠️ " + e.message); }
    });
    li.querySelector('[data-a="decline"]').addEventListener("click", async () => {
      try {
        await rpc("respond_friend_request", { request_id: r.id, accept: false });
        poll();
      } catch (e) { toast("⚠️ " + e.message); }
    });
    list.appendChild(li);
  });
}

function updateFriendMarkers(friends) {
  const activeIds = new Set();
  friends.forEach((f) => {
    if (!f.location) return;
    activeIds.add(String(f.id));
    const cls = f.partner ? "partner" : (f.online ? "" : "offline");
    const icon = avatarIcon(f.avatar, cls);
    const popup = `<b>${f.partner ? "💗 " : ""}${escapeHtml(friendLabel(f))}</b><br>${
      f.online ? "Online now" : "Last seen " + fmtAgo(f.lastSeen)
    }${f.distance != null ? "<br>" + fmtDist(f.distance) + " away" : ""}`;
    if (!markers[f.id]) {
      markers[f.id] = L.marker([f.location.lat, f.location.lng], { icon }).addTo(map);
      markers[f.id].bindPopup(popup);
    } else {
      markers[f.id].setIcon(icon);
      markers[f.id].setLatLng([f.location.lat, f.location.lng]);
      markers[f.id].getPopup().setContent(popup);
    }
  });
  Object.keys(markers).forEach((id) => {
    if (!activeIds.has(String(id))) {
      map.removeLayer(markers[id]);
      delete markers[id];
    }
  });
}

/* ---------------- Shared pet ---------------- */
const PET_VERBS = { feed: "fed", play: "played with", clean: "cleaned", cuddle: "cuddled" };
const PET_FX = { feed: "🍎", play: "🎾", clean: "🛁", cuddle: "💞" };

function petLevel(xp) { return 1 + Math.floor((xp || 0) / 100); }

/* Streak stays "alive" only if you were both together today or yesterday. */
function todayStr() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
function streakAlive(pet) {
  if (!pet.lastTogether) return false;
  const last = new Date(pet.lastTogether + "T00:00:00");
  const days = Math.floor((Date.now() - last.getTime()) / 86400000);
  return days <= 1;
}

/* ---- Pet care reminders (local notifications via the service worker) ---- */
const NOTIFY_KEY = "bebi-pet-notify";
const NOTIFY_STATE_KEY = "bebi-pet-notify-state";

function petNotifyEnabled() { return localStorage.getItem(NOTIFY_KEY) === "1"; }

async function setPetNotify(on) {
  if (!on) { localStorage.setItem(NOTIFY_KEY, "0"); return false; }
  if (!("Notification" in window)) { toast("Notifications aren't supported on this device"); return false; }
  let perm = Notification.permission;
  if (perm === "default") perm = await Notification.requestPermission();
  if (perm !== "granted") {
    toast("🔕 Turn notifications on for Bebi Time in your browser settings");
    return false;
  }
  localStorage.setItem(NOTIFY_KEY, "1");
  toast("🔔 Reminders on — we'll nudge you when your pet needs care");
  return true;
}

function petNeedLabel(pt) {
  const m = Math.min(pt.hunger, pt.fun, pt.clean);
  if (pt.hunger === m) return "hungry 🍎";
  if (pt.clean === m) return "needs a bath 🛁";
  return "bored 🎾";
}

function showPetNotification(pt) {
  const f = pt.partnerId ? friendById(pt.partnerId) : null;
  const name = pt.name || "Your pet";
  const withWho = f ? ` with ${friendLabel(f)}` : "";
  const opts = {
    body: `${name} is ${petNeedLabel(pt)}. Tap to care for it${withWho} 💗`,
    icon: "icons/icon-192.png",
    badge: "icons/icon-192.png",
    tag: "pet-" + pt.id, // replaces the previous nudge for this pet
    data: { url: location.href },
  };
  const title = `🐾 ${name} needs you`;
  if (navigator.serviceWorker && navigator.serviceWorker.ready) {
    navigator.serviceWorker.ready
      .then((reg) => reg.showNotification(title, opts))
      .catch(() => { try { new Notification(title, opts); } catch (_) {} });
  } else {
    try { new Notification(title, opts); } catch (_) {}
  }
}

/* Fire one nudge per pet when a stat first drops low; re-arm once it recovers. */
function maybePetNotify() {
  if (!petNotifyEnabled() || !("Notification" in window) || Notification.permission !== "granted") return;
  let state = {};
  try { state = JSON.parse(localStorage.getItem(NOTIFY_STATE_KEY) || "{}"); } catch (_) {}
  let changed = false;
  Object.values(petsById).forEach((pt) => {
    const minv = Math.min(pt.hunger, pt.fun, pt.clean);
    if (minv < 25 && !state[pt.id]) {
      showPetNotification(pt);
      state[pt.id] = true; changed = true;
    } else if (minv > 45 && state[pt.id]) {
      state[pt.id] = false; changed = true; // recovered — allow the next nudge
    }
  });
  if (changed) localStorage.setItem(NOTIFY_STATE_KEY, JSON.stringify(state));
}

function petMood(pet) {
  const { hunger, fun, clean } = pet;
  const minv = Math.min(hunger, fun, clean);
  const avg = (hunger + fun + clean) / 3;
  if (minv < 15) {
    if (hunger === minv) return "🍽️";
    if (clean === minv) return "🧼";
    return "😢";
  }
  if (avg >= 80) return "😻";
  if (avg >= 60) return "😊";
  if (avg >= 40) return "🙂";
  if (avg >= 25) return "😕";
  return "😢";
}

function petCaredBy(pet, partner) {
  if (!pet.lastAction) return "Newly hatched 🐣 — say hello!";
  const who = pet.lastActor === uid ? "You" : partner ? friendLabel(partner) : "Someone";
  const verb = PET_VERBS[pet.lastAction] || "cared for";
  return `${escapeHtml(who)} ${verb} ${escapeHtml(pet.name || "your pet")} recently 💗`;
}

function setPetBar(sel, v) {
  const el = $(sel);
  const val = Math.max(0, Math.min(100, Math.round(v)));
  el.style.width = val + "%";
  el.className = val < 25 ? "low" : val < 50 ? "warn" : "";
}

function currentPet() { return petSelectedId != null ? petsById[petSelectedId] : null; }

function renderPet() {
  renderPetInvites();
  const pets = Object.values(petsById);

  if (petSelectedId == null || !petsById[petSelectedId]) {
    petSelectedId = pets.length ? pets[0].id : null;
  }

  // Pet switcher only appears when I care for more than one pet.
  if (pets.length > 1) { buildPetSelect(pets); $("#pet-switch").classList.remove("hidden"); }
  else $("#pet-switch").classList.add("hidden");

  if (!pets.length) {
    $("#pet-card").classList.add("hidden");
    $("#pet-editor").classList.add("hidden");
    $("#pet-hatch").classList.remove("hidden");
    return;
  }
  $("#pet-hatch").classList.add("hidden");
  renderPetCard(petsById[petSelectedId]);
}

/* Incoming "will you co-parent my pet?" requests. */
function renderPetInvites() {
  const wrap = $("#pet-invites");
  wrap.innerHTML = "";
  petInvitesList.forEach((inv) => {
    const card = document.createElement("div");
    card.className = "pet-invite-card";
    card.innerHTML = `
      <span class="pet-invite-species">${inv.species || "🐣"}</span>
      <div class="pet-invite-text">
        <b>${escapeHtml(inv.fromName || "A friend")}</b> wants you to co-parent
        <b>${escapeHtml(inv.petName || "their pet")}</b> 🐾
      </div>
      <div class="pet-invite-actions">
        <button class="btn primary small" data-a="accept">Accept</button>
        <button class="btn ghost small" data-a="decline">Decline</button>
      </div>`;
    card.querySelector('[data-a="accept"]').addEventListener("click", () => respondCoparent(inv.id, true, inv.petId));
    card.querySelector('[data-a="decline"]').addEventListener("click", () => respondCoparent(inv.id, false));
    wrap.appendChild(card);
  });
}

function buildPetSelect(pets) {
  const sel = $("#pet-select");
  const sig = pets.map((p) => p.id + ":" + p.name + ":" + (p.isOwner ? 1 : 0) + ":" + (p.partnerId || "")).join("|");
  if (sel.dataset.sig !== sig) {
    sel.innerHTML = "";
    pets.forEach((p) => {
      const o = document.createElement("option");
      o.value = p.id;
      const partner = p.partnerId ? friendById(p.partnerId) : null;
      const withWho = partner ? ` · with ${friendLabel(partner)}` : (p.isOwner ? " · solo" : "");
      o.textContent = `${p.species || "🐣"} ${p.name || "Bebi"}${withWho}`;
      sel.appendChild(o);
    });
    sel.dataset.sig = sig;
  }
  sel.value = petSelectedId;
}

function renderPetCard(pet) {
  const partner = pet.partnerId ? friendById(pet.partnerId) : null;
  $("#pet-card").classList.remove("hidden");
  $("#pet-avatar").textContent = pet.species || "🐣";
  $("#pet-mood").textContent = petMood(pet);
  $("#pet-name").textContent = pet.name || "Bebi";
  $("#pet-level").textContent = "Lv " + petLevel(pet.xp);
  $("#pet-level").title = (pet.xp % 100) + " / 100 XP";
  const streakEl = $("#pet-streak");
  if (pet.streak > 0 && streakAlive(pet)) {
    streakEl.textContent = "🔥 " + pet.streak;
    streakEl.title = `${pet.streak}-day together streak — you both showed up ${
      pet.lastTogether === todayStr() ? "today" : "yesterday"}. Keep it going!`;
    streakEl.classList.remove("hidden");
  } else {
    streakEl.classList.add("hidden");
  }
  $("#pet-caredby").innerHTML = petCaredBy(pet, partner);
  setPetBar("#pet-bar-hunger", pet.hunger);
  setPetBar("#pet-bar-fun", pet.fun);
  setPetBar("#pet-bar-clean", pet.clean);
  renderCoparentSection(pet, partner);
}

/* The co-parent status + controls, rebuilt from the pet's current state. */
function renderCoparentSection(pet, partner) {
  const box = $("#pet-coparent");
  box.innerHTML = "";

  // Already co-parented — show who, plus a way out (either carer can leave).
  if (pet.coparentId) {
    const name = partner ? friendLabel(partner) : "your co-parent";
    box.appendChild(coparentStatus(`💗 Co-parenting with <b>${escapeHtml(name)}</b>`));
    const leave = ghostButton("End co-parenting", () => {
      if (confirm(`Stop co-parenting ${pet.name || "this pet"} with ${name}?`)) removeCoparent(pet.id);
    });
    box.appendChild(leave);
    return;
  }

  // Only the owner can invite (a non-owner without a co-parent isn't a carer).
  if (!pet.isOwner) return;

  // Waiting on a reply.
  if (pet.pendingInvite) {
    const invitee = friendById(pet.pendingInvite.toId);
    const nm = invitee ? friendLabel(invitee) : "your friend";
    box.appendChild(coparentStatus(`⏳ Waiting for <b>${escapeHtml(nm)}</b> to accept…`));
    box.appendChild(ghostButton("Cancel request", () => cancelCoparent(pet.id)));
    return;
  }

  // Solo — offer to invite a co-parent.
  box.appendChild(coparentStatus(`🐾 You're raising <b>${escapeHtml(pet.name || "your pet")}</b> solo.`));
  if (!currentFriends.length) {
    const hint = document.createElement("p");
    hint.className = "muted small";
    hint.textContent = "Add a friend from the Invite tab, then you can ask them to co-parent.";
    box.appendChild(hint);
    return;
  }
  const row = document.createElement("div");
  row.className = "coparent-invite-row";
  const sel = document.createElement("select");
  currentFriends.forEach((fr) => {
    const o = document.createElement("option");
    o.value = fr.id;
    o.textContent = (fr.partner ? "💗 " : "") + friendLabel(fr);
    sel.appendChild(o);
  });
  const btn = document.createElement("button");
  btn.className = "btn primary small";
  btn.textContent = "Invite 💌";
  btn.addEventListener("click", () => inviteCoparent(pet.id, sel.value));
  row.appendChild(sel);
  row.appendChild(btn);
  box.appendChild(row);
}

function coparentStatus(html) {
  const d = document.createElement("div");
  d.className = "coparent-status";
  d.innerHTML = html;
  return d;
}
function ghostButton(label, onClick) {
  const b = document.createElement("button");
  b.className = "btn ghost small coparent-btn";
  b.textContent = label;
  b.addEventListener("click", onClick);
  return b;
}

async function inviteCoparent(petId, friendId) {
  if (!friendId) return;
  try {
    await rpc("invite_coparent", { p_pet_id: petId, p_friend_id: friendId });
    const fr = friendById(friendId);
    toast(`💌 Co-parent request sent to ${fr ? friendLabel(fr) : "your friend"}`);
    await poll();
  } catch (e) { toast("⚠️ " + e.message); }
}
async function cancelCoparent(petId) {
  try { await rpc("cancel_coparent", { p_pet_id: petId }); toast("Request cancelled"); await poll(); }
  catch (e) { toast("⚠️ " + e.message); }
}
async function removeCoparent(petId) {
  try { await rpc("remove_coparent", { p_pet_id: petId }); toast("Co-parenting ended"); await poll(); }
  catch (e) { toast("⚠️ " + e.message); }
}
async function respondCoparent(inviteId, accept, petId) {
  try {
    await rpc("respond_coparent", { p_invite_id: inviteId, p_accept: accept });
    toast(accept ? "💗 You're co-parenting now!" : "Declined");
    if (accept && petId != null) petSelectedId = petId;
    await poll();
  } catch (e) { toast("⚠️ " + e.message); }
}

function updatePetAlert() {
  const badge = $("#pet-alert");
  const invites = petInvitesList.length;
  let needs = 0;
  Object.values(petsById).forEach((pt) => {
    if (Math.min(pt.hunger, pt.fun, pt.clean) < 25) needs++;
  });
  badge.textContent = invites ? String(invites) : needs ? "!" : "";
  badge.dataset.zero = invites === 0 && needs === 0;
}

function petFloat(emoji) {
  const stage = $(".pet-stage");
  if (!stage) return;
  const el = document.createElement("span");
  el.className = "pet-float";
  el.textContent = emoji;
  stage.appendChild(el);
  setTimeout(() => el.remove(), 1100);
}

async function doPetAction(action) {
  if (petSelectedId == null) return;
  try {
    const pet = await rpc("pet_action", { p_pet_id: petSelectedId, p_action: action });
    petsById[pet.id] = pet;
    renderPetCard(pet);
    updatePetAlert();
    const av = $("#pet-avatar");
    av.classList.remove("bounce"); void av.offsetWidth; av.classList.add("bounce");
    petFloat(PET_FX[action] || "✨");
  } catch (e) { toast("⚠️ " + e.message); }
}

function buildSpeciesPicker(selected) {
  const wrap = $("#pet-species");
  wrap.innerHTML = "";
  PET_SPECIES.forEach((s) => {
    const el = document.createElement("button");
    el.type = "button";
    el.className = "species-opt" + (s === selected ? " selected" : "");
    el.textContent = s;
    el.addEventListener("click", () => {
      $$("#pet-species .species-opt").forEach((x) => x.classList.remove("selected"));
      el.classList.add("selected");
      wrap.dataset.selected = s;
    });
    wrap.appendChild(el);
  });
  wrap.dataset.selected = selected || PET_SPECIES[0];
}

$("#pet-select").addEventListener("change", (e) => {
  petSelectedId = e.target.value;
  $("#pet-editor").classList.add("hidden");
  renderPet();
});

$("#pet-hatch-btn").addEventListener("click", async () => {
  try {
    const pet = await rpc("hatch_pet", {});
    petsById[pet.id] = pet;
    petSelectedId = pet.id;
    toast("🐣 Your pet hatched — say hi!");
    renderPet();
    updatePetAlert();
  } catch (e) { toast("⚠️ " + e.message); }
});

$$(".pet-act").forEach((b) =>
  b.addEventListener("click", () => doPetAction(b.dataset.action))
);

$("#pet-edit-btn").addEventListener("click", () => {
  const editor = $("#pet-editor");
  const nowHidden = editor.classList.toggle("hidden");
  if (!nowHidden) {
    const pet = currentPet();
    $("#pet-name-input").value = pet?.name || "";
    buildSpeciesPicker(pet?.species);
  }
});

$("#pet-notify-toggle").addEventListener("change", async (e) => {
  const ok = await setPetNotify(e.target.checked);
  e.target.checked = ok;
});

$("#pet-save-btn").addEventListener("click", async () => {
  if (petSelectedId == null) return;
  try {
    const pet = await rpc("set_pet", {
      p_pet_id: petSelectedId,
      p_name: $("#pet-name-input").value.trim(),
      p_species: $("#pet-species").dataset.selected || "",
    });
    petsById[pet.id] = pet;
    $("#pet-editor").classList.add("hidden");
    renderPetCard(pet);
    toast("Saved ✓");
  } catch (e) { toast("⚠️ " + e.message); }
});

/* ---------------- Pings / toast ---------------- */
const PING_EMOJI = {
  wave: "👋", heart: "❤️", hug: "🫂", coffee: "☕", thinking: "💭",
  kiss: "😘", love: "❤️", miss: "🥺", omw: "🚗",
};
const PING_TEXT = {
  miss: "misses you", omw: "is on the way to you 🚗", thinking: "is thinking of you 💭",
};
function showPing(p) {
  const emoji = PING_EMOJI[p.kind] || "✨";
  const verb = PING_TEXT[p.kind];
  const msg = verb
    ? `${p.avatar} ${escapeHtml(p.from)} ${verb}`
    : `${p.avatar} ${escapeHtml(p.from)} sent you ${emoji}`;
  toast(msg, 4000);
}
let toastTimer = null;
function toast(msg, ms = 2200) {
  const t = $("#toast");
  t.innerHTML = msg;
  t.classList.remove("hidden");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.add("hidden"), ms);
}

/* ---------------- Invite panel ---------------- */
$("#copy-code").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(me.friendCode);
    toast("Copied " + me.friendCode);
  } catch {
    toast(me.friendCode);
  }
});

$("#add-friend-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("#friend-code-input");
  const code = input.value.trim().toUpperCase();
  if (!code) return;
  try {
    const r = await rpc("send_friend_request", { target_code: code });
    if (r.instant) toast("🤝 You're now friends with " + r.friend);
    else toast("✉️ Request sent to " + r.sentTo);
    input.value = "";
    poll();
  } catch (err) {
    toast("⚠️ " + err.message, 3200);
  }
});

/* ---------------- You panel ---------------- */
function buildAvatarPicker() {
  const picker = $("#avatar-picker");
  picker.innerHTML = "";
  AVATARS.forEach((a) => {
    const el = document.createElement("div");
    el.className = "avatar-opt" + (a === me?.avatar ? " selected" : "");
    el.textContent = a;
    el.addEventListener("click", () => {
      $$(".avatar-opt").forEach((x) => x.classList.remove("selected"));
      el.classList.add("selected");
      picker.dataset.selected = a;
    });
    picker.appendChild(el);
  });
  picker.dataset.selected = me?.avatar || AVATARS[0];
  $("#name-input").value = me?.displayName || "";
  $("#mood-input").value = me?.mood || "";
  $("#note-input").value = me?.note || "";
}

$("#save-profile").addEventListener("click", async () => {
  const displayName = $("#name-input").value.trim();
  if (!displayName) { toast("⚠️ Please enter a name"); return; }
  const payload = {
    display_name: displayName,
    avatar: $("#avatar-picker").dataset.selected,
    mood: $("#mood-input").value.trim(),
    note: $("#note-input").value.trim(),
  };
  try {
    const { error } = await sb.from("profiles").update(payload).eq("id", uid);
    if (error) throw error;
    me = { ...me, displayName, avatar: payload.avatar, mood: payload.mood, note: payload.note };
    renderMe();
    if (myMarker) myMarker.setIcon(avatarIcon(me.avatar, "me"));
    toast("Saved ✓");
  } catch (err) {
    toast("⚠️ " + err.message);
  }
});

$("#share-toggle").addEventListener("change", (e) => {
  sharing = e.target.checked;
  if (sharing) {
    startLocation();
    $("#loc-hint").textContent = "Using your device GPS.";
  } else {
    if (geoWatch) navigator.geolocation.clearWatch(geoWatch);
    $("#loc-hint").textContent = "Location sharing paused.";
    $("#me-status").textContent = "Paused";
  }
});

$("#manual-loc").addEventListener("click", () => {
  manualMode = !manualMode;
  $("#manual-loc").textContent = manualMode
    ? "Tap anywhere on the map…"
    : "Set location by tapping map (demo)";
  if (manualMode) collapseSheet();
});

$("#logout-btn").addEventListener("click", logout);

async function logout() {
  try { await sb.auth.signOut(); } catch {}
  if (pollTimer) clearInterval(pollTimer);
  if (geoWatch) navigator.geolocation.clearWatch(geoWatch);
  if (rtChannel) { try { sb.removeChannel(rtChannel); } catch {} rtChannel = null; }
  location.reload();
}

/* ---------------- Sheet + recenter ---------------- */
$$(".sheet-tab").forEach((t) =>
  t.addEventListener("click", () => {
    $$(".sheet-tab").forEach((x) => x.classList.remove("active"));
    t.classList.add("active");
    $$(".panel").forEach((p) => p.classList.remove("active"));
    $("#panel-" + t.dataset.panel).classList.add("active");
    if (t.dataset.panel === "pet") renderPet();
    expandSheet();
  })
);

let sheetCollapsed = false;
function collapseSheet() { $("#sheet").classList.add("collapsed"); sheetCollapsed = true; }
function expandSheet() { $("#sheet").classList.remove("collapsed"); sheetCollapsed = false; }
$("#sheet-handle").addEventListener("click", () =>
  sheetCollapsed ? expandSheet() : collapseSheet()
);

$("#recenter-btn").addEventListener("click", () => {
  followMe = true;
  if (myMarker) map.setView(myMarker.getLatLng(), 16, { animate: true });
  else toast("Waiting for your location…");
});

/* ---------------- Utils ---------------- */
function haversineJS(lat1, lon1, lat2, lon2) {
  const R = 6371000, toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1), dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}
function fmtDist(m) {
  if (m < 1000) return m + " m";
  return (m / 1000).toFixed(m < 10000 ? 1 : 0) + " km";
}
function fmtAgo(ts) {
  const s = Math.max(0, Date.now() / 1000 - ts);
  if (s < 60) return "just now";
  if (s < 3600) return Math.floor(s / 60) + "m ago";
  if (s < 86400) return Math.floor(s / 3600) + "h ago";
  return Math.floor(s / 86400) + "d ago";
}
function fmtTime(iso) {
  const d = new Date(iso);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}
/* Couple banner: show how far apart you and your partner are, on the map. */
function updateDuoBanner(friends) {
  const banner = $("#duo-banner");
  const partner = (friends || []).find((f) => f.partner && f.distance != null);
  if (partner && myLatLng) {
    banner.textContent = `💗 You & ${friendLabel(partner)} — ${fmtDist(partner.distance)} apart`;
    banner.classList.remove("hidden");
  } else {
    banner.classList.add("hidden");
  }
}
function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
  );
}

/* ---------------- Boot ---------------- */
(async function boot() {
  if (!configured) {
    $("#setup-warning").classList.remove("hidden");
    return;
  }
  try {
    const { data } = await sb.auth.getSession();
    if (data.session) {
      uid = data.session.user.id;
      enterApp();
      return;
    }
  } catch (_) {}
  $("#auth").classList.remove("hidden");
})();

/* Sign the user out cleanly if their session is revoked elsewhere. */
if (sb) {
  sb.auth.onAuthStateChange((event) => {
    if (event === "SIGNED_OUT" && !$("#app").classList.contains("hidden")) {
      location.reload();
    }
  });
}
