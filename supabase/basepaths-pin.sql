-- =====================================================================
-- Basepaths: easier team search, and PINs for grown-ups on a shared phone.
--
-- HOW TO RUN: Supabase > SQL Editor > paste all of this > Run.
-- Run it AFTER basepaths-fans.sql. Safe to run again.
--
--  * Team search matches any of the words you type, in the team name,
--    age group, season, town or a coach's name. Spaces and capitals
--    don't matter ("big dawgz", "bigdawgz 12u" and "dawgz" all work).
--    Best matches come first.
--  * Parents and coaches set a 4-digit PIN. On a phone with more than one
--    profile, the PIN is needed to open a grown-up's profile. Five wrong
--    PINs lock it for 5 minutes.
-- =====================================================================

-- ---------- search ----------
create or replace function dg_norm(t text) returns text
language sql immutable as $$ select regexp_replace(lower(coalesce(t, '')), '[^a-z0-9]+', '', 'g') $$;

create or replace function dz_org_search(p_tok text, p_q text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users; q text := lower(trim(coalesce(p_q, ''))); w text[]; qn text;
begin
  u := dg_user(p_tok);
  qn := dg_norm(q);
  if length(qn) < 2 then return jsonb_build_object('orgs', '[]'::jsonb); end if;
  -- words worth matching on; small filler words are dropped unless they're all you typed
  select coalesce(array_agg(x), '{}') into w from (
    select dg_norm(x) x from unnest(regexp_split_to_array(q, '[^a-z0-9]+')) x
    where length(dg_norm(x)) >= 2 and dg_norm(x) not in ('the','team','baseball','travel','club','of','and','fc','bb')) s;
  if cardinality(w) = 0 then w := array[qn]; end if;
  return jsonb_build_object('orgs', coalesce((
    select jsonb_agg(dg_org_card(o) || jsonb_build_object('mine', m.status, 'role', m.role) order by r.score desc, o.year desc nulls last, o.name)
    from (
      select o2.id,
        (case when position(qn in h.hay) > 0 then 10 else 0 end)
        + (case when dg_norm(o2.name) like qn || '%' then 5 else 0 end)
        + (select count(*) from unnest(w) x where position(x in h.hay) > 0) * 3
        + (select count(*) from unnest(w) x where length(x) >= 4 and position(left(x, length(x) - 1) in h.hay) > 0) as score
      from dg_orgs o2
      cross join lateral (select dg_norm(o2.name) || '|' || dg_norm(o2.age) || '|' || coalesce(o2.year::text, '') || '|' || dg_norm(o2.city) || '|'
          || coalesce((select string_agg(dg_norm(x.name), '|') from dg_members mm join dg_users x on x.id = mm.account_id
                       where mm.org_id = o2.id and mm.role = 'coach' and mm.status = 'active'), '') as hay) h
      where o2.status = 'active') r
    join dg_orgs o on o.id = r.id
    left join dg_members m on m.org_id = o.id and m.account_id = u.id
    where r.score > 0
    limit 30), '[]'::jsonb));
end $$;

-- ---------- PINs ----------
alter table dg_users add column if not exists pin text;
alter table dg_users add column if not exists pin_fail int not null default 0;
alter table dg_users add column if not exists pin_until timestamptz;

-- set or change your PIN (needs your password)
create or replace function dz_pin_set(p_tok text, p_pw text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u dg_users;
begin
  u := dg_user(p_tok);
  if u.kid then raise exception 'parents_only'; end if;
  if u.pw <> extensions.crypt(coalesce(p_pw, ''), u.pw) then raise exception 'bad_password'; end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then raise exception 'bad_pin_format'; end if;
  update dg_users set pin = extensions.crypt(p_pin, extensions.gen_salt('bf')), pin_fail = 0, pin_until = null where id = u.id;
  return jsonb_build_object('ok', true);
end $$;

-- open a grown-up's profile with their PIN
create or replace function dz_pin_check(p_tok text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u dg_users;
begin
  u := dg_user(p_tok);
  if u.pin is null then raise exception 'no_pin'; end if;
  if u.pin_until is not null and u.pin_until > now() then return jsonb_build_object('ok', false, 'err', 'pin_locked'); end if;
  if u.pin <> extensions.crypt(coalesce(p_pin, ''), u.pin) then
    -- count the miss (no exception here, so the count is kept)
    update dg_users set pin_until = case when pin_fail + 1 >= 5 then now() + interval '5 minutes' else null end,
      pin_fail = case when pin_fail + 1 >= 5 then 0 else pin_fail + 1 end where id = u.id;
    return jsonb_build_object('ok', false, 'err', 'bad_pin');
  end if;
  update dg_users set pin_fail = 0, pin_until = null where id = u.id;
  return jsonb_build_object('ok', true);
end $$;

-- profiles now say whether the grown-up has a PIN
create or replace function dz_profiles(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users;
begin
  u := dg_user(p_tok);
  return jsonb_build_object('me', jsonb_build_object('id', u.id, 'name', u.name, 'role', u.role, 'kid', u.kid, 'email', case when u.kid then split_part(u.email, '@', 1) else u.email end, 'pin', u.pin is not null),
    'kids', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'user', case when k.kid then split_part(k.email, '@', 1) else k.email end) order by k.name)
      from dg_users k where k.parent_id = u.id and k.consent_at is not null), '[]'::jsonb));
end $$;

grant execute on function dz_org_search(text,text), dz_pin_set(text,text,text), dz_pin_check(text,text), dz_profiles(text) to anon, authenticated;
revoke execute on function dg_norm(text) from public, anon, authenticated;

do $$ declare r record; begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'dz\_%' or p.proname like 'dg\_%') and p.prokind = 'f' loop
    execute 'alter function ' || r.sig || ' set search_path = public, extensions';
  end loop;
end $$;

notify pgrst, 'reload schema';
