-- ============================================================================
-- Bebi Time — Supabase schema, security rules, and API functions
-- Run this ONCE in your Supabase project: SQL Editor -> New query -> paste ->
-- Run. Safe to re-run (everything is "create or replace" / "if not exists").
-- ============================================================================

-- ---------- Tables ----------------------------------------------------------

create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Friend',
  friend_code  text unique not null,
  avatar       text not null default '🦊',
  mood         text not null default '',
  note         text not null default '',
  updated_at   timestamptz not null default now()
);

create table if not exists public.friendships (
  user_a uuid not null references auth.users(id) on delete cascade,
  user_b uuid not null references auth.users(id) on delete cascade,
  since  timestamptz not null default now(),
  primary key (user_a, user_b)  -- always stored normalized: user_a < user_b
);

create table if not exists public.friend_requests (
  id         bigint generated always as identity primary key,
  from_id    uuid not null references auth.users(id) on delete cascade,
  to_id      uuid not null references auth.users(id) on delete cascade,
  status     text not null default 'pending',
  created_at timestamptz not null default now(),
  unique (from_id, to_id)
);

create table if not exists public.locations (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  lat        double precision not null,
  lng        double precision not null,
  accuracy   double precision default 0,
  battery    int,
  updated_at timestamptz not null default now()
);

create table if not exists public.pings (
  id         bigint generated always as identity primary key,
  from_id    uuid not null references auth.users(id) on delete cascade,
  to_id      uuid not null references auth.users(id) on delete cascade,
  kind       text not null,
  created_at timestamptz not null default now(),
  seen       boolean not null default false
);

-- Per-viewer settings about a friend: a private nickname only YOU see, whether
-- they're your partner ♥, and your "together since" date.
create table if not exists public.friend_meta (
  owner_id  uuid not null references auth.users(id) on delete cascade,
  friend_id uuid not null references auth.users(id) on delete cascade,
  nickname  text not null default '',
  partner   boolean not null default false,
  since     date,
  primary key (owner_id, friend_id)
);

-- Direct messages between two friends.
create table if not exists public.messages (
  id         bigint generated always as identity primary key,
  from_id    uuid not null references auth.users(id) on delete cascade,
  to_id      uuid not null references auth.users(id) on delete cascade,
  body       text not null,
  created_at timestamptz not null default now(),
  read       boolean not null default false
);
create index if not exists messages_pair_idx on public.messages (from_id, to_id, created_at);

-- Optional attachment on a message: a photo or file kept in Supabase Storage. Only the
-- storage PATH + metadata live here; the bytes live in the private 'chat-attachments'
-- bucket, fetched via short-lived signed URLs (see the Storage section near the bottom).
alter table public.messages add column if not exists attachment_path text;
alter table public.messages add column if not exists attachment_type text;   -- mime type
alter table public.messages add column if not exists attachment_name text;   -- original filename
alter table public.messages add column if not exists attachment_size bigint; -- bytes
-- A message may now be attachment-only (no text), so allow an empty body.
alter table public.messages alter column body set default '';

-- Reply-to: a message can quote an earlier one. reply_preview is a small text snapshot
-- of the quoted message so the bubble renders without a join.
alter table public.messages add column if not exists reply_to bigint references public.messages(id) on delete set null;
alter table public.messages add column if not exists reply_preview text;

-- Edit / unsend support:
--  edited_at  — set when the sender edits the body.
--  unsent     — "unsent for everyone": content cleared, both see a tombstone.
--  hidden_from / hidden_to — "unsent for you": hides the message from just that side.
alter table public.messages add column if not exists edited_at   timestamptz;
alter table public.messages add column if not exists unsent      boolean not null default false;
alter table public.messages add column if not exists hidden_from boolean not null default false;
alter table public.messages add column if not exists hidden_to   boolean not null default false;

-- Emoji reactions on a message. One reaction per person per message (a new emoji
-- replaces the old one; PK enforces it). Deleting the reaction row un-reacts.
create table if not exists public.message_reactions (
  message_id bigint not null references public.messages(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  emoji      text not null,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

-- A virtual pet. Every pet has an OWNER who created it and cares for it; the owner
-- may invite ONE co-parent to raise it with them. Until (and unless) someone accepts,
-- the owner cares for it solo. Stats are 0..100 and decay over real time; the stored
-- value is "the value at updated_at", decay is computed on read (no cron needed).
--
-- ONE-TIME MIGRATION ONLY: the earliest version of this app used a pair-keyed pets
-- table (user_a/user_b). If that old shape is detected we drop it so the new tables
-- below can be created. On a NORMAL re-run (new structure already in place) NOTHING is
-- dropped — so re-running this script to pick up changes KEEPS ALL EXISTING PETS.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'pets' and column_name = 'user_a'
  ) then
    drop table if exists public.pet_invites cascade;
    drop table if exists public.pets cascade;
  end if;
end $$;

create table if not exists public.pets (
  id           bigint generated always as identity primary key,
  owner_id     uuid not null references auth.users(id) on delete cascade,
  coparent_id  uuid references auth.users(id) on delete set null,
  name         text not null default 'Pet',
  species      text not null default '🐣',
  hunger       int  not null default 80,
  fun          int  not null default 80,
  clean        int  not null default 80,
  xp           int  not null default 0,
  born_at      timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  last_action  text,
  last_actor   uuid references auth.users(id) on delete set null,
  -- "Together streak": consecutive days BOTH carers showed up (only once co-parented).
  streak         int  not null default 0,
  last_together  date,
  seen_owner     date,
  seen_coparent  date
);
-- Forward-compatible: add any column a slightly older copy of this table may be missing,
-- so future re-runs stay non-destructive (data preserved).
alter table public.pets add column if not exists coparent_id   uuid references auth.users(id) on delete set null;
alter table public.pets add column if not exists last_action   text;
alter table public.pets add column if not exists last_actor    uuid references auth.users(id) on delete set null;
alter table public.pets add column if not exists streak        int not null default 0;
alter table public.pets add column if not exists last_together date;
alter table public.pets add column if not exists seen_owner    date;
alter table public.pets add column if not exists seen_coparent date;
create index if not exists pets_owner_idx    on public.pets(owner_id);
create index if not exists pets_coparent_idx on public.pets(coparent_id);

-- A pending "will you co-parent my pet?" request. One pending invite per pet.
create table if not exists public.pet_invites (
  id         bigint generated always as identity primary key,
  pet_id     bigint not null references public.pets(id) on delete cascade,
  from_id    uuid not null references auth.users(id) on delete cascade,
  to_id      uuid not null references auth.users(id) on delete cascade,
  status     text not null default 'pending',
  created_at timestamptz not null default now()
);
create unique index if not exists pet_invites_one_pending
  on public.pet_invites(pet_id) where status = 'pending';

-- Activity feed: a durable log of things that happened FOR a user (pings received,
-- friend requests & new friendships, co-parent invites & accepts…). Rows are written
-- automatically by triggers below, so no RPC needs to remember to log.
create table if not exists public.notifications (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade, -- who sees it
  kind       text not null,        -- 'ping' | 'friend_request' | 'friend_new' | 'coparent_invite' | 'coparent_accept'
  actor_id   uuid references auth.users(id) on delete set null,         -- who caused it
  detail     text,                 -- extra context (ping kind, pet name…)
  created_at timestamptz not null default now(),
  read       boolean not null default false
);
create index if not exists notifications_user_idx on public.notifications(user_id, id desc);

-- ---------- Helper functions ------------------------------------------------

-- Distance between two lat/lng points, in meters.
create or replace function public.haversine(
  lat1 double precision, lon1 double precision,
  lat2 double precision, lon2 double precision
) returns double precision
language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) *
    power(sin(radians(lon2 - lon1) / 2), 2)
  ));
$$;

-- Are two users friends? SECURITY DEFINER so it can be used inside RLS
-- policies without causing recursive permission checks.
create or replace function public.are_friends(a uuid, b uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.friendships
    where user_a = least(a, b) and user_b = greatest(a, b)
  );
$$;

-- Decay one pet stat: reduce the stored value by `rate` points per hour elapsed
-- since it was last updated, clamped to 0..100. Used on read so pets get hungrier
-- / bored / dirtier as real time passes, with no background job.
create or replace function public.pet_decay(base int, updated timestamptz, rate numeric)
returns int
language sql stable as $$
  select greatest(0, least(100,
    round(base - (extract(epoch from (now() - updated)) / 3600.0) * rate)
  ))::int;
$$;

-- Generate a unique, human-friendly 6-char friend code (no ambiguous chars).
create or replace function public.gen_friend_code()
returns text
language plpgsql as $$
declare
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  code text;
  i int;
begin
  loop
    code := '';
    for i in 1..6 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.profiles where friend_code = code);
  end loop;
  return code;
end;
$$;

-- When a new auth user is created, auto-create their profile + friend code.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  avatars text[] := array['🦊','🐼','🐨','🐯','🦁','🐸','🐵','🦉','🐧','🦄','🐙','🌸','⭐','🔥','🌊','🍀','🐺','🦈'];
begin
  insert into public.profiles (id, display_name, friend_code, avatar)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'display_name', ''), 'Friend'),
    public.gen_friend_code(),
    avatars[1 + floor(random() * array_length(avatars, 1))::int]
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Activity feed triggers ------------------------------------------
-- These write rows into public.notifications whenever something social happens,
-- so the app's Activity tab has a complete history with no per-RPC bookkeeping.

-- A ping arrived -> notify the recipient (detail = the ping kind, e.g. 'kiss').
create or replace function public.notify_on_ping()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, kind, actor_id, detail)
    values (new.to_id, 'ping', new.from_id, new.kind);
  return new;
end $$;
drop trigger if exists trg_notify_ping on public.pings;
create trigger trg_notify_ping after insert on public.pings
  for each row execute function public.notify_on_ping();

-- A friend request was sent -> notify the recipient.
create or replace function public.notify_on_friend_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and new.status = 'pending' then
    insert into public.notifications (user_id, kind, actor_id)
      values (new.to_id, 'friend_request', new.from_id);
  end if;
  return new;
end $$;
drop trigger if exists trg_notify_friend_request on public.friend_requests;
create trigger trg_notify_friend_request after insert on public.friend_requests
  for each row execute function public.notify_on_friend_request();

-- A friendship formed -> notify BOTH people (covers "your request was accepted").
create or replace function public.notify_on_friendship()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, kind, actor_id) values
    (new.user_a, 'friend_new', new.user_b),
    (new.user_b, 'friend_new', new.user_a);
  return new;
end $$;
drop trigger if exists trg_notify_friendship on public.friendships;
create trigger trg_notify_friendship after insert on public.friendships
  for each row execute function public.notify_on_friendship();

-- A co-parent invite was sent -> notify invitee; when accepted -> notify the owner.
create or replace function public.notify_on_pet_invite()
returns trigger language plpgsql security definer set search_path = public as $$
declare petname text;
begin
  select name into petname from public.pets where id = new.pet_id;
  if tg_op = 'INSERT' and new.status = 'pending' then
    insert into public.notifications (user_id, kind, actor_id, detail)
      values (new.to_id, 'coparent_invite', new.from_id, petname);
  elsif tg_op = 'UPDATE' and new.status = 'accepted' and old.status is distinct from 'accepted' then
    insert into public.notifications (user_id, kind, actor_id, detail)
      values (new.from_id, 'coparent_accept', new.to_id, petname);
  end if;
  return new;
end $$;
drop trigger if exists trg_notify_pet_invite on public.pet_invites;
create trigger trg_notify_pet_invite after insert or update on public.pet_invites
  for each row execute function public.notify_on_pet_invite();

-- ---------- Row Level Security ----------------------------------------------
-- With RLS on, the public anon key CANNOT read anyone's data except what these
-- policies allow. This is what keeps locations private to friends.

alter table public.profiles        enable row level security;
alter table public.friendships     enable row level security;
alter table public.friend_requests enable row level security;
alter table public.locations       enable row level security;
alter table public.pings           enable row level security;
alter table public.friend_meta     enable row level security;
alter table public.messages        enable row level security;
alter table public.message_reactions enable row level security;
alter table public.pets            enable row level security;
alter table public.pet_invites     enable row level security;
alter table public.notifications   enable row level security;

-- profiles: you can read your own + your friends'; edit only your own.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select
  using (id = auth.uid() or public.are_friends(auth.uid(), id));
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

-- locations: you can read your own + your friends'; write only your own.
drop policy if exists locations_select on public.locations;
create policy locations_select on public.locations for select
  using (user_id = auth.uid() or public.are_friends(auth.uid(), user_id));
drop policy if exists locations_insert on public.locations;
create policy locations_insert on public.locations for insert
  with check (user_id = auth.uid());
drop policy if exists locations_update on public.locations;
create policy locations_update on public.locations for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- friend_requests / pings are only ever touched through the functions below,
-- but we still add read policies so nothing leaks even on direct access.
drop policy if exists requests_select on public.friend_requests;
create policy requests_select on public.friend_requests for select
  using (from_id = auth.uid() or to_id = auth.uid());
drop policy if exists pings_select on public.pings;
create policy pings_select on public.pings for select
  using (from_id = auth.uid() or to_id = auth.uid());

-- friend_meta: you can read/write only the rows you own (your private notes).
drop policy if exists friend_meta_all on public.friend_meta;
create policy friend_meta_all on public.friend_meta for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- messages: you can read messages you sent or received; send only as yourself
-- and only to a friend; mark received messages as read.
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select
  using (from_id = auth.uid() or to_id = auth.uid());
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert
  with check (from_id = auth.uid() and public.are_friends(auth.uid(), to_id));
drop policy if exists messages_update on public.messages;
create policy messages_update on public.messages for update
  using (to_id = auth.uid()) with check (to_id = auth.uid());

-- message_reactions: you can READ every reaction on a message you're part of (yours
-- and your friend's), but only add/change/remove your OWN reactions.
drop policy if exists message_reactions_read on public.message_reactions;
create policy message_reactions_read on public.message_reactions for select
  using (exists (
    select 1 from public.messages m
    where m.id = message_reactions.message_id
      and (m.from_id = auth.uid() or m.to_id = auth.uid())
  ));
drop policy if exists message_reactions_own on public.message_reactions;
create policy message_reactions_own on public.message_reactions for all
  using (user_id = auth.uid() and exists (
    select 1 from public.messages m
    where m.id = message_reactions.message_id
      and (m.from_id = auth.uid() or m.to_id = auth.uid())
  ))
  with check (user_id = auth.uid() and exists (
    select 1 from public.messages m
    where m.id = message_reactions.message_id
      and (m.from_id = auth.uid() or m.to_id = auth.uid())
  ));

-- pets: the owner and the accepted co-parent may READ the pet (needed for realtime).
-- All writes go through the SECURITY DEFINER functions below, so no write policy.
drop policy if exists pets_select on public.pets;
create policy pets_select on public.pets for select
  using (auth.uid() = owner_id or auth.uid() = coparent_id);

-- pet_invites: you can read invites you sent or received. Writes go through functions.
drop policy if exists pet_invites_select on public.pet_invites;
create policy pet_invites_select on public.pet_invites for select
  using (from_id = auth.uid() or to_id = auth.uid());

-- notifications: you can read & mark-read only your own. Inserts come from triggers.
drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications for select
  using (user_id = auth.uid());
drop policy if exists notifications_update on public.notifications;
create policy notifications_update on public.notifications for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- API functions (called from the browser via supabase.rpc) --------

-- Everything the app needs to render, in one call. SECURITY DEFINER so it can
-- assemble friends' data; it is always scoped to the caller via auth.uid().
create or replace function public.get_state()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me       uuid := auth.uid();
  my_loc   locations%rowtype;
  mylat    double precision;
  mylng    double precision;
  has_loc  boolean;
  friends  jsonb;
  requests jsonb;
  pings    jsonb;
  pets        jsonb;
  pet_invites jsonb;
  notifs        jsonb;
  notifs_unread bigint;
  me_json  jsonb;
begin
  if me is null then
    raise exception 'Not authenticated';
  end if;

  -- heartbeat: mark me as recently seen
  update public.profiles set updated_at = now() where id = me;

  -- Couple streak heartbeat: stamp "I showed up today" on my pets, then advance the
  -- streak on any co-parented pet where BOTH carers have shown up today. The guards
  -- (`is distinct from` / `last_together < current_date`) mean each pet is written at
  -- most once per person per day — no write amplification, no realtime ping-pong.
  update public.pets set seen_owner = current_date
    where owner_id = me and (seen_owner is distinct from current_date);
  update public.pets set seen_coparent = current_date
    where coparent_id = me and (seen_coparent is distinct from current_date);
  update public.pets
    set streak = case when last_together = current_date - 1 then streak + 1 else 1 end,
        last_together = current_date
    where coparent_id is not null
      and (owner_id = me or coparent_id = me)
      and seen_owner = current_date and seen_coparent = current_date
      and (last_together is null or last_together < current_date);

  select * into my_loc from public.locations where user_id = me;
  mylat := my_loc.lat;
  mylng := my_loc.lng;
  has_loc := my_loc.user_id is not null;

  select coalesce(jsonb_agg(f), '[]'::jsonb) into friends from (
    select
      p.id,
      p.display_name as "displayName",
      coalesce(nullif(fm.nickname, ''), null) as nickname,
      coalesce(fm.partner, false) as partner,
      fm.since,
      p.avatar,
      p.mood,
      p.note,
      (p.updated_at > now() - interval '45 seconds') as online,
      extract(epoch from p.updated_at) as "lastSeen",
      (select count(*) from public.messages m
        where m.to_id = me and m.from_id = p.id and m.read = false) as unread,
      case when l.user_id is not null then jsonb_build_object(
        'lat', l.lat, 'lng', l.lng, 'accuracy', l.accuracy,
        'battery', l.battery, 'updatedAt', extract(epoch from l.updated_at)
      ) else null end as location,
      case when l.user_id is not null and has_loc then
        round(public.haversine(mylat, mylng, l.lat, l.lng)::numeric)
      else null end as distance
    from public.friendships fr
    join public.profiles p
      on p.id = case when fr.user_a = me then fr.user_b else fr.user_a end
    left join public.locations l on l.user_id = p.id
    left join public.friend_meta fm on fm.owner_id = me and fm.friend_id = p.id
    where fr.user_a = me or fr.user_b = me
    order by coalesce(fm.partner, false) desc, online desc, p.display_name
  ) f;

  select coalesce(jsonb_agg(r), '[]'::jsonb) into requests from (
    select fr.id, p.display_name as "displayName", p.avatar, p.friend_code as code
    from public.friend_requests fr
    join public.profiles p on p.id = fr.from_id
    where fr.to_id = me and fr.status = 'pending'
    order by fr.id
  ) r;

  select coalesce(jsonb_agg(pg), '[]'::jsonb) into pings from (
    select p2.id, p2.kind, extract(epoch from p2.created_at) as "createdAt",
           pr.display_name as "from", pr.avatar
    from public.pings p2
    join public.profiles pr on pr.id = p2.from_id
    where p2.to_id = me and p2.seen = false
    order by p2.id
  ) pg;
  update public.pings set seen = true where to_id = me and seen = false;

  -- Pets I care for (as owner or accepted co-parent), with live-decayed stats and,
  -- for the owner, any pending co-parent invite still waiting on a reply.
  select coalesce(jsonb_agg(pt), '[]'::jsonb) into pets from (
    select
      pe.id,
      pe.name, pe.species,
      public.pet_decay(pe.hunger, pe.updated_at, 4)   as hunger,
      public.pet_decay(pe.fun,    pe.updated_at, 3)   as fun,
      public.pet_decay(pe.clean,  pe.updated_at, 2.5) as clean,
      pe.xp,
      pe.streak,
      pe.last_together as "lastTogether",
      pe.last_action as "lastAction",
      pe.last_actor  as "lastActor",
      pe.owner_id    as "ownerId",
      pe.coparent_id as "coparentId",
      (pe.owner_id = me) as "isOwner",
      case when pe.owner_id = me then pe.coparent_id else pe.owner_id end as "partnerId",
      (select jsonb_build_object('id', inv.id, 'toId', inv.to_id)
         from public.pet_invites inv
         where inv.pet_id = pe.id and inv.status = 'pending' limit 1) as "pendingInvite",
      extract(epoch from pe.updated_at) as "updatedAt"
    from public.pets pe
    where pe.owner_id = me or pe.coparent_id = me
    order by pe.id
  ) pt;

  -- Incoming "co-parent my pet?" requests addressed to me.
  select coalesce(jsonb_agg(iv), '[]'::jsonb) into pet_invites from (
    select inv.id, inv.pet_id as "petId",
           pe.name as "petName", pe.species,
           inv.from_id as "fromId",
           pr.display_name as "fromName", pr.avatar as "fromAvatar"
    from public.pet_invites inv
    join public.pets pe on pe.id = inv.pet_id
    join public.profiles pr on pr.id = inv.from_id
    where inv.to_id = me and inv.status = 'pending'
    order by inv.id
  ) iv;

  -- Activity feed: newest 40 notifications for me, plus how many are unread.
  select coalesce(jsonb_agg(nt), '[]'::jsonb) into notifs from (
    select n.id, n.kind, n.detail, n.read,
           extract(epoch from n.created_at) as "at",
           n.actor_id as "actorId",
           pr.display_name as "actorName",
           pr.avatar as "actorAvatar"
    from public.notifications n
    left join public.profiles pr on pr.id = n.actor_id
    where n.user_id = me
    order by n.id desc
    limit 40
  ) nt;
  select count(*) into notifs_unread from public.notifications where user_id = me and read = false;

  select jsonb_build_object(
    'id', p.id, 'displayName', p.display_name, 'avatar', p.avatar,
    'mood', p.mood, 'note', p.note, 'friendCode', p.friend_code
  ) into me_json from public.profiles p where p.id = me;

  return jsonb_build_object(
    'me', me_json,
    'myLocation', case when has_loc then jsonb_build_object('lat', mylat, 'lng', mylng) else null end,
    'friends', friends,
    'requests', requests,
    'pings', pings,
    'pets', pets,
    'petInvites', pet_invites,
    'notifications', notifs,
    'notifsUnread', notifs_unread,
    'serverTime', extract(epoch from now())
  );
end;
$$;

-- Send (or auto-accept, if mutual) a friend request by code.
create or replace function public.send_friend_request(target_code text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me       uuid := auth.uid();
  target   public.profiles%rowtype;
  incoming public.friend_requests%rowtype;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  select * into target from public.profiles where friend_code = upper(trim(target_code));
  if not found then raise exception 'No one has that code.'; end if;
  if target.id = me then raise exception 'That is your own code 🙂'; end if;
  if public.are_friends(me, target.id) then raise exception 'You are already friends.'; end if;

  select * into incoming from public.friend_requests
    where from_id = target.id and to_id = me and status = 'pending';
  if found then
    insert into public.friendships (user_a, user_b)
      values (least(me, target.id), greatest(me, target.id)) on conflict do nothing;
    update public.friend_requests set status = 'accepted' where id = incoming.id;
    return jsonb_build_object('instant', true, 'friend', target.display_name);
  end if;

  insert into public.friend_requests (from_id, to_id, status)
    values (me, target.id, 'pending')
    on conflict (from_id, to_id) do update set status = 'pending', created_at = now();
  return jsonb_build_object('sentTo', target.display_name);
end;
$$;

-- Accept or decline a pending request addressed to me.
create or replace function public.respond_friend_request(request_id bigint, accept boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me  uuid := auth.uid();
  req public.friend_requests%rowtype;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  select * into req from public.friend_requests
    where id = request_id and to_id = me and status = 'pending';
  if not found then raise exception 'Request not found.'; end if;
  if accept then
    insert into public.friendships (user_a, user_b)
      values (least(me, req.from_id), greatest(me, req.from_id)) on conflict do nothing;
    update public.friend_requests set status = 'accepted' where id = request_id;
  else
    update public.friend_requests set status = 'declined' where id = request_id;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Remove a friend (and clean up any request history).
create or replace function public.remove_friend(friend_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not authenticated'; end if;
  delete from public.friendships
    where user_a = least(me, friend_id) and user_b = greatest(me, friend_id);
  delete from public.friend_requests
    where (from_id = me and to_id = friend_id) or (from_id = friend_id and to_id = me);
  return jsonb_build_object('ok', true);
end;
$$;

-- Send a playful ping (wave/heart/hug…) to a friend.
-- Params are p_-prefixed so they never collide with the target tables' own columns
-- (e.g. pings.kind / friend_meta.friend_id), which would raise "column reference … is
-- ambiguous". create-or-replace can't rename params, so drop the old signature first.
drop function if exists public.send_ping(uuid, text);
create function public.send_ping(p_friend_id uuid, p_kind text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not authenticated'; end if;
  if not public.are_friends(me, p_friend_id) then
    raise exception 'You can only ping friends.';
  end if;
  insert into public.pings (from_id, to_id, kind)
    values (me, p_friend_id, coalesce(nullif(p_kind, ''), 'wave'));
  return jsonb_build_object('ok', true);
end;
$$;

-- Set a private nickname for a friend (only you see it). Empty clears it.
drop function if exists public.set_friend_nickname(uuid, text);
create function public.set_friend_nickname(p_friend_id uuid, p_nickname text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not authenticated'; end if;
  if not public.are_friends(me, p_friend_id) then
    raise exception 'Not your friend.';
  end if;
  insert into public.friend_meta (owner_id, friend_id, nickname)
    values (me, p_friend_id, coalesce(trim(p_nickname), ''))
    on conflict (owner_id, friend_id) do update set nickname = excluded.nickname;
  return jsonb_build_object('ok', true);
end;
$$;

-- Mark a friend as your partner ♥ (and optionally your "together since" date).
drop function if exists public.set_partner(uuid, boolean, date);
create function public.set_partner(p_friend_id uuid, p_is_partner boolean, p_since_date date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not authenticated'; end if;
  if not public.are_friends(me, p_friend_id) then
    raise exception 'Not your friend.';
  end if;
  insert into public.friend_meta (owner_id, friend_id, partner, since)
    values (me, p_friend_id, coalesce(p_is_partner, false), p_since_date)
    on conflict (owner_id, friend_id) do update
      set partner = excluded.partner, since = excluded.since;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- Pet (owner + optional co-parent) --------------------------------

-- Old pair-keyed signatures are gone; drop them so we can recreate cleanly.
drop function if exists public.get_pet(uuid);
drop function if exists public.pet_action(uuid, text);
drop function if exists public.set_pet(uuid, text, text);

-- Serialize a pet row (with live-decayed stats) from `me`'s point of view.
create or replace function public.pet_json(pe public.pets, me uuid)
returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', pe.id,
    'name', pe.name, 'species', pe.species,
    'hunger', public.pet_decay(pe.hunger, pe.updated_at, 4),
    'fun',    public.pet_decay(pe.fun,    pe.updated_at, 3),
    'clean',  public.pet_decay(pe.clean,  pe.updated_at, 2.5),
    'xp', pe.xp,
    'streak', pe.streak,
    'lastTogether', pe.last_together,
    'lastAction', pe.last_action,
    'lastActor', pe.last_actor,
    'ownerId', pe.owner_id,
    'coparentId', pe.coparent_id,
    'isOwner', (pe.owner_id = me),
    'partnerId', case when pe.owner_id = me then pe.coparent_id else pe.owner_id end,
    'updatedAt', extract(epoch from pe.updated_at)
  );
$$;

-- True if `me` is allowed to care for this pet (owner or accepted co-parent).
create or replace function public.pet_is_carer(pe public.pets, me uuid)
returns boolean language sql immutable as $$
  select me = pe.owner_id or me = pe.coparent_id;
$$;

-- Create a new pet (solo) that I own. You can have as many as you like, up to a
-- generous safety cap that just stops a runaway loop from filling the table.
create or replace function public.hatch_pet()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pe public.pets%rowtype; n int;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  select count(*) into n from public.pets where owner_id = me;
  if n >= 20 then raise exception 'You already have 20 pets — that''s the limit for now.'; end if;
  insert into public.pets (owner_id) values (me) returning * into pe;
  return public.pet_json(pe, me);
end $$;

-- Owner invites a friend to co-parent. Replaces any existing pending invite for
-- the pet (so you can change your mind about whom to ask).
create or replace function public.invite_coparent(p_pet_id bigint, p_friend_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pe public.pets%rowtype;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  select * into pe from public.pets where id = p_pet_id;
  if not found then raise exception 'Pet not found.'; end if;
  if pe.owner_id <> me then raise exception 'Only the owner can invite a co-parent.'; end if;
  if pe.coparent_id is not null then raise exception 'This pet already has a co-parent.'; end if;
  if p_friend_id = me then raise exception 'You cannot co-parent with yourself 🙂'; end if;
  if not public.are_friends(me, p_friend_id) then raise exception 'You can only invite a friend.'; end if;

  update public.pet_invites
    set to_id = p_friend_id, from_id = me, created_at = now()
    where pet_id = p_pet_id and status = 'pending';
  if not found then
    insert into public.pet_invites (pet_id, from_id, to_id)
      values (p_pet_id, me, p_friend_id);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Owner cancels their pending invite (pet stays solo).
create or replace function public.cancel_coparent(p_pet_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not authenticated'; end if;
  delete from public.pet_invites
    where pet_id = p_pet_id and from_id = me and status = 'pending';
  return jsonb_build_object('ok', true);
end $$;

-- The invited person accepts (becomes co-parent) or declines (owner stays solo).
create or replace function public.respond_coparent(p_invite_id bigint, p_accept boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); inv public.pet_invites%rowtype;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  select * into inv from public.pet_invites
    where id = p_invite_id and to_id = me and status = 'pending';
  if not found then raise exception 'Request not found.'; end if;

  if p_accept then
    -- only attach if the pet still has no co-parent
    update public.pets set coparent_id = me
      where id = inv.pet_id and coparent_id is null;
    if not found then raise exception 'This pet already has a co-parent.'; end if;
    update public.pet_invites set status = 'accepted' where id = p_invite_id;
  else
    update public.pet_invites set status = 'declined' where id = p_invite_id;
  end if;
  return jsonb_build_object('ok', true, 'accepted', p_accept);
end $$;

-- End co-parenting (either the owner or the co-parent may leave). The pet reverts
-- to a solo pet owned by the owner, and the streak resets.
create or replace function public.remove_coparent(p_pet_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pe public.pets%rowtype;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  select * into pe from public.pets where id = p_pet_id;
  if not found then raise exception 'Pet not found.'; end if;
  if not public.pet_is_carer(pe, me) then raise exception 'Not your pet.'; end if;
  update public.pets
    set coparent_id = null, streak = 0, last_together = null, seen_coparent = null
    where id = p_pet_id;
  return jsonb_build_object('ok', true);
end $$;

-- Release (permanently delete) a pet. Owner-only — a co-parent uses remove_coparent
-- to step away instead. Deleting the pet cascades away its co-parent invites.
create or replace function public.release_pet(p_pet_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pe public.pets%rowtype;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  select * into pe from public.pets where id = p_pet_id;
  if not found then raise exception 'Pet not found.'; end if;
  if pe.owner_id <> me then raise exception 'Only the owner can release this pet.'; end if;
  delete from public.pets where id = p_pet_id;
  return jsonb_build_object('ok', true);
end $$;

-- Care for the pet: feed / play / clean / cuddle. Applies decay first so the boost
-- stacks on the pet's real current state, then bumps XP. Any carer may do this.
create or replace function public.pet_action(p_pet_id bigint, p_action text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  pe public.pets%rowtype;
  h int; f int; c int; gainxp int := 0;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  select * into pe from public.pets where id = p_pet_id;
  if not found then raise exception 'Pet not found.'; end if;
  if not public.pet_is_carer(pe, me) then raise exception 'Not your pet.'; end if;

  h := public.pet_decay(pe.hunger, pe.updated_at, 4);
  f := public.pet_decay(pe.fun,    pe.updated_at, 3);
  c := public.pet_decay(pe.clean,  pe.updated_at, 2.5);

  if p_action = 'feed' then
    h := least(100, h + 35); gainxp := 5;
  elsif p_action = 'treat' then
    h := least(100, h + 18); f := least(100, f + 12); gainxp := 4;
  elsif p_action = 'play' then
    f := least(100, f + 35); h := greatest(0, h - 5); gainxp := 5;
  elsif p_action = 'walk' then
    f := least(100, f + 22); h := greatest(0, h - 8); c := greatest(0, c - 10); gainxp := 6;
  elsif p_action = 'sing' then
    f := least(100, f + 18); gainxp := 3;
  elsif p_action = 'clean' then
    c := least(100, c + 40); gainxp := 4;
  elsif p_action = 'cuddle' then
    f := least(100, f + 15); gainxp := 3;
  elsif p_action = 'nap' then
    f := least(100, f + 10); h := greatest(0, h - 3); gainxp := 3;
  else
    raise exception 'Unknown action.';
  end if;

  update public.pets
    set hunger = h, fun = f, clean = c, xp = pe.xp + gainxp,
        updated_at = now(), last_action = p_action, last_actor = me
    where id = p_pet_id
    returning * into pe;

  return public.pet_json(pe, me);
end $$;

-- Rename / restyle the pet (any carer).
create or replace function public.set_pet(p_pet_id bigint, p_name text, p_species text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pe public.pets%rowtype;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  select * into pe from public.pets where id = p_pet_id;
  if not found then raise exception 'Pet not found.'; end if;
  if not public.pet_is_carer(pe, me) then raise exception 'Not your pet.'; end if;
  update public.pets
    set name = coalesce(nullif(trim(p_name), ''), name),
        species = coalesce(nullif(p_species, ''), species)
    where id = p_pet_id
    returning * into pe;
  return public.pet_json(pe, me);
end $$;

-- Mark all my notifications as read (called when I open the Activity tab).
create or replace function public.mark_notifs_read()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not authenticated'; end if;
  update public.notifications set read = true where user_id = me and read = false;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Chat message: edit / unsend --------------------------------------

-- Edit my own message (sender only, not already unsent).
create or replace function public.edit_message(p_msg_id bigint, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m public.messages%rowtype;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  select * into m from public.messages where id = p_msg_id;
  if not found then raise exception 'Message not found.'; end if;
  if m.from_id <> me then raise exception 'You can only edit your own messages.'; end if;
  if m.unsent then raise exception 'This message was unsent.'; end if;
  update public.messages set body = coalesce(p_body, ''), edited_at = now() where id = p_msg_id;
  return jsonb_build_object('ok', true);
end $$;

-- Unsend for EVERYONE (sender only): wipe the content, leave a tombstone both sides see.
create or replace function public.unsend_message(p_msg_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m public.messages%rowtype;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  select * into m from public.messages where id = p_msg_id;
  if not found then raise exception 'Message not found.'; end if;
  if m.from_id <> me then raise exception 'You can only unsend your own messages.'; end if;
  update public.messages
    set unsent = true, body = '', reply_preview = null, edited_at = now(),
        attachment_path = null, attachment_type = null, attachment_name = null, attachment_size = null
    where id = p_msg_id;
  delete from public.message_reactions where message_id = p_msg_id;
  return jsonb_build_object('ok', true);
end $$;

-- Unsend for ME only (either participant): hide it from my own view.
create or replace function public.delete_message_for_me(p_msg_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m public.messages%rowtype;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  select * into m from public.messages where id = p_msg_id;
  if not found then raise exception 'Message not found.'; end if;
  if me = m.from_id then update public.messages set hidden_from = true where id = p_msg_id;
  elsif me = m.to_id then update public.messages set hidden_to = true where id = p_msg_id;
  else raise exception 'Not your conversation.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Grants ----------------------------------------------------------
-- Let logged-in users call the functions and touch their own rows.
grant usage on schema public to anon, authenticated;
grant select, insert, update on public.locations to authenticated;
grant select, update on public.profiles to authenticated;
grant select, insert, update on public.messages to authenticated;
grant select, insert, update, delete on public.message_reactions to authenticated;
grant execute on function public.edit_message(bigint, text) to authenticated;
grant execute on function public.unsend_message(bigint) to authenticated;
grant execute on function public.delete_message_for_me(bigint) to authenticated;
grant select, insert, update, delete on public.friend_meta to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.get_state() to authenticated;
grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_friend_request(bigint, boolean) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;
grant execute on function public.send_ping(uuid, text) to authenticated;
grant execute on function public.set_friend_nickname(uuid, text) to authenticated;
grant execute on function public.set_partner(uuid, boolean, date) to authenticated;
grant select on public.pets to authenticated;
grant select on public.pet_invites to authenticated;
grant execute on function public.hatch_pet() to authenticated;
grant execute on function public.invite_coparent(bigint, uuid) to authenticated;
grant execute on function public.cancel_coparent(bigint) to authenticated;
grant execute on function public.respond_coparent(bigint, boolean) to authenticated;
grant execute on function public.remove_coparent(bigint) to authenticated;
grant execute on function public.release_pet(bigint) to authenticated;
grant execute on function public.pet_action(bigint, text) to authenticated;
grant execute on function public.set_pet(bigint, text, text) to authenticated;
grant select, update on public.notifications to authenticated;
grant execute on function public.mark_notifs_read() to authenticated;

-- ---------- Realtime (instant live updates) ---------------------------------
-- Push row changes to the browser the moment they happen, so friends move on the
-- map with no delay. Row Level Security still applies — each client only ever
-- receives their own + accepted friends' rows. Safe to re-run (errors ignored
-- if a table is already published or the publication is absent).
do $$
begin
  begin alter publication supabase_realtime add table public.locations;        exception when others then null; end;
  begin alter publication supabase_realtime add table public.pings;            exception when others then null; end;
  begin alter publication supabase_realtime add table public.friend_requests;  exception when others then null; end;
  begin alter publication supabase_realtime add table public.messages;         exception when others then null; end;
  begin alter publication supabase_realtime add table public.message_reactions; exception when others then null; end;
  begin alter publication supabase_realtime add table public.pets;             exception when others then null; end;
  begin alter publication supabase_realtime add table public.pet_invites;      exception when others then null; end;
  begin alter publication supabase_realtime add table public.notifications;    exception when others then null; end;
end $$;

-- ---------- Storage: chat attachments ---------------------------------------
-- A PRIVATE bucket for photos/files sent in chat. The bytes are never public; the
-- client uploads here and then shows them via short-lived signed URLs. Access is
-- gated by the policies below so only the two people in a conversation can read a file.
insert into storage.buckets (id, name, public)
  values ('chat-attachments', 'chat-attachments', false)
  on conflict (id) do nothing;

-- Upload: any signed-in user may add files they own to this bucket.
drop policy if exists chat_attach_insert on storage.objects;
create policy chat_attach_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-attachments' and owner = auth.uid());

-- Read: the uploader, OR the recipient of a message that references this exact file.
-- (createSignedUrl is checked against this policy, so only participants can view it.)
drop policy if exists chat_attach_select on storage.objects;
create policy chat_attach_select on storage.objects for select to authenticated
  using (
    bucket_id = 'chat-attachments' and (
      owner = auth.uid()
      or exists (
        select 1 from public.messages m
        where m.attachment_path = storage.objects.name and m.to_id = auth.uid()
      )
    )
  );

-- Delete: you can remove files you uploaded.
drop policy if exists chat_attach_delete on storage.objects;
create policy chat_attach_delete on storage.objects for delete to authenticated
  using (bucket_id = 'chat-attachments' and owner = auth.uid());
