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

-- A shared virtual pet, one per pair of people (stored normalized: user_a < user_b,
-- exactly like friendships). Both people see and care for the SAME pet. Stats are
-- 0..100 and decay over real time; the stored value is "the value at updated_at",
-- and decay is computed on read so we don't need any cron/background job.
create table if not exists public.pets (
  user_a      uuid not null references auth.users(id) on delete cascade,
  user_b      uuid not null references auth.users(id) on delete cascade,
  name        text not null default 'Bebi',
  species     text not null default '🐣',
  hunger      int  not null default 80,
  fun         int  not null default 80,
  clean       int  not null default 80,
  xp          int  not null default 0,
  born_at     timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  last_action text,
  last_actor  uuid references auth.users(id) on delete set null,
  -- "Together streak": consecutive days BOTH people showed up for the pet.
  streak         int  not null default 0,
  last_together  date,
  seen_a         date,
  seen_b         date,
  primary key (user_a, user_b),
  check (user_a < user_b)
);
-- Add the streak columns to pre-existing pets tables too (safe to re-run).
alter table public.pets add column if not exists streak        int not null default 0;
alter table public.pets add column if not exists last_together date;
alter table public.pets add column if not exists seen_a        date;
alter table public.pets add column if not exists seen_b        date;

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
alter table public.pets            enable row level security;

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

-- pets: either member of the pair may READ the shared pet (needed for realtime).
-- All writes go through the SECURITY DEFINER functions below, so no write policy.
drop policy if exists pets_select on public.pets;
create policy pets_select on public.pets for select
  using (auth.uid() = user_a or auth.uid() = user_b);

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
  pets     jsonb;
  me_json  jsonb;
begin
  if me is null then
    raise exception 'Not authenticated';
  end if;

  -- heartbeat: mark me as recently seen
  update public.profiles set updated_at = now() where id = me;

  -- Couple streak heartbeat: stamp "I showed up today" on all my shared pets, then
  -- advance the streak on any pair where BOTH of us have shown up today. The guards
  -- (`is distinct from` / `last_together < current_date`) mean each pet is written at
  -- most once per person per day — no write amplification, no realtime ping-pong.
  update public.pets set seen_a = current_date
    where user_a = me and (seen_a is distinct from current_date);
  update public.pets set seen_b = current_date
    where user_b = me and (seen_b is distinct from current_date);
  update public.pets
    set streak = case when last_together = current_date - 1 then streak + 1 else 1 end,
        last_together = current_date
    where (user_a = me or user_b = me)
      and seen_a = current_date and seen_b = current_date
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

  -- Shared pets, keyed by the OTHER person in the pair, with live-decayed stats.
  select coalesce(jsonb_agg(pt), '[]'::jsonb) into pets from (
    select
      case when pe.user_a = me then pe.user_b else pe.user_a end as "friendId",
      pe.name, pe.species,
      public.pet_decay(pe.hunger, pe.updated_at, 4)   as hunger,
      public.pet_decay(pe.fun,    pe.updated_at, 3)   as fun,
      public.pet_decay(pe.clean,  pe.updated_at, 2.5) as clean,
      pe.xp,
      pe.streak,
      pe.last_together as "lastTogether",
      pe.last_action as "lastAction",
      pe.last_actor  as "lastActor",
      extract(epoch from pe.updated_at) as "updatedAt"
    from public.pets pe
    where pe.user_a = me or pe.user_b = me
  ) pt;

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
create or replace function public.send_ping(friend_id uuid, kind text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not authenticated'; end if;
  if not public.are_friends(me, friend_id) then
    raise exception 'You can only ping friends.';
  end if;
  insert into public.pings (from_id, to_id, kind)
    values (me, friend_id, coalesce(nullif(kind, ''), 'wave'));
  return jsonb_build_object('ok', true);
end;
$$;

-- Set a private nickname for a friend (only you see it). Empty clears it.
create or replace function public.set_friend_nickname(friend_id uuid, nickname text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not authenticated'; end if;
  if not public.are_friends(me, friend_id) then
    raise exception 'Not your friend.';
  end if;
  insert into public.friend_meta (owner_id, friend_id, nickname)
    values (me, friend_id, coalesce(trim(nickname), ''))
    on conflict (owner_id, friend_id) do update set nickname = excluded.nickname;
  return jsonb_build_object('ok', true);
end;
$$;

-- Mark a friend as your partner ♥ (and optionally your "together since" date).
create or replace function public.set_partner(friend_id uuid, is_partner boolean, since_date date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not authenticated'; end if;
  if not public.are_friends(me, friend_id) then
    raise exception 'Not your friend.';
  end if;
  insert into public.friend_meta (owner_id, friend_id, partner, since)
    values (me, friend_id, coalesce(is_partner, false), since_date)
    on conflict (owner_id, friend_id) do update
      set partner = excluded.partner, since = excluded.since;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- Shared pet ------------------------------------------------------

-- Serialize a pet row (with live-decayed stats) for the caller.
create or replace function public.pet_json(pe public.pets, me uuid)
returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'friendId', case when pe.user_a = me then pe.user_b else pe.user_a end,
    'name', pe.name, 'species', pe.species,
    'hunger', public.pet_decay(pe.hunger, pe.updated_at, 4),
    'fun',    public.pet_decay(pe.fun,    pe.updated_at, 3),
    'clean',  public.pet_decay(pe.clean,  pe.updated_at, 2.5),
    'xp', pe.xp,
    'streak', pe.streak,
    'lastTogether', pe.last_together,
    'lastAction', pe.last_action,
    'lastActor', pe.last_actor,
    'updatedAt', extract(epoch from pe.updated_at)
  );
$$;

-- Fetch (hatching it if this pair doesn't have one yet) the shared pet.
create or replace function public.get_pet(friend_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  a uuid; b uuid;
  pe public.pets%rowtype;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  if not public.are_friends(me, friend_id) then raise exception 'Not your friend.'; end if;
  a := least(me, friend_id); b := greatest(me, friend_id);
  select * into pe from public.pets where user_a = a and user_b = b;
  if not found then
    insert into public.pets (user_a, user_b) values (a, b)
      on conflict (user_a, user_b) do nothing;
    select * into pe from public.pets where user_a = a and user_b = b;
  end if;
  return public.pet_json(pe, me);
end $$;

-- Care for the shared pet: feed / play / clean / cuddle. Applies decay first so
-- the boost stacks on the pet's real current state, then bumps XP.
create or replace function public.pet_action(friend_id uuid, action text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  a uuid; b uuid;
  pe public.pets%rowtype;
  h int; f int; c int; gainxp int := 0;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  if not public.are_friends(me, friend_id) then raise exception 'Not your friend.'; end if;
  a := least(me, friend_id); b := greatest(me, friend_id);
  select * into pe from public.pets where user_a = a and user_b = b;
  if not found then
    insert into public.pets (user_a, user_b) values (a, b) on conflict (user_a, user_b) do nothing;
    select * into pe from public.pets where user_a = a and user_b = b;
  end if;

  h := public.pet_decay(pe.hunger, pe.updated_at, 4);
  f := public.pet_decay(pe.fun,    pe.updated_at, 3);
  c := public.pet_decay(pe.clean,  pe.updated_at, 2.5);

  if action = 'feed' then
    h := least(100, h + 35); gainxp := 5;
  elsif action = 'play' then
    f := least(100, f + 35); h := greatest(0, h - 5); gainxp := 5;
  elsif action = 'clean' then
    c := least(100, c + 40); gainxp := 4;
  elsif action = 'cuddle' then
    f := least(100, f + 15); gainxp := 3;
  else
    raise exception 'Unknown action.';
  end if;

  update public.pets
    set hunger = h, fun = f, clean = c, xp = pe.xp + gainxp,
        updated_at = now(), last_action = action, last_actor = me
    where user_a = a and user_b = b
    returning * into pe;

  return public.pet_json(pe, me);
end $$;

-- Rename / restyle the shared pet (either partner can).
create or replace function public.set_pet(friend_id uuid, new_name text, new_species text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  a uuid; b uuid; pe public.pets%rowtype;
begin
  if me is null then raise exception 'Not authenticated'; end if;
  if not public.are_friends(me, friend_id) then raise exception 'Not your friend.'; end if;
  a := least(me, friend_id); b := greatest(me, friend_id);
  update public.pets
    set name = coalesce(nullif(trim(new_name), ''), name),
        species = coalesce(nullif(new_species, ''), species)
    where user_a = a and user_b = b
    returning * into pe;
  if not found then raise exception 'No pet yet — hatch one first.'; end if;
  return public.pet_json(pe, me);
end $$;

-- ---------- Grants ----------------------------------------------------------
-- Let logged-in users call the functions and touch their own rows.
grant usage on schema public to anon, authenticated;
grant select, insert, update on public.locations to authenticated;
grant select, update on public.profiles to authenticated;
grant select, insert, update on public.messages to authenticated;
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
grant execute on function public.get_pet(uuid) to authenticated;
grant execute on function public.pet_action(uuid, text) to authenticated;
grant execute on function public.set_pet(uuid, text, text) to authenticated;

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
  begin alter publication supabase_realtime add table public.pets;             exception when others then null; end;
end $$;
