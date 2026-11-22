-- =====================================================================
-- Basepaths: drill videos players send to their coach.
--
-- HOW TO RUN: Supabase > SQL Editor > paste all of this > Run.
-- Run it AFTER basepaths-orgs.sql and basepaths-kids.sql. Safe to run again.
-- Then deploy the Edge Function in supabase/functions/drill-videos (see README).
--
--  * Coach assigns homework as "Just watch", "Do the drill" or "Do it + send me a video".
--  * A player uploads a clip (up to 60 seconds, 100 MB) into a PRIVATE storage bucket.
--  * Only coaches on that team can watch it, through a link that expires in 1 hour.
--  * When the coach marks it watched, the file is deleted.
--  * Clips that never finished uploading are cleaned up after a day.
--  * A team can hold about 900 MB of unwatched clips at once (free plan has 1 GB).
-- These functions are only called by the drill-videos Edge Function, never by the app directly.
-- =====================================================================

create table if not exists dg_videos (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references dg_orgs(id) on delete cascade,
  player_id uuid not null references dg_players_all(id) on delete cascade,
  account_id uuid not null references dg_users(id) on delete cascade,
  drill text not null default '',
  hw_aid text not null default '',
  path text not null,
  size bigint not null default 0,
  status text not null default 'uploading' check (status in ('uploading','sent','seen')),
  created_at timestamptz not null default now(),
  seen_at timestamptz
);
create index if not exists dg_videos_org on dg_videos(org_id, status);
create index if not exists dg_videos_acct on dg_videos(account_id, created_at);
alter table dg_videos enable row level security;
revoke all on dg_videos from anon, authenticated;

-- private bucket: video files only, 100 MB each
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('drill-videos', 'drill-videos', false, 104857600, array['video/*'])
on conflict (id) do update set public = false,
  file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- player starts an upload: checks who they are and makes a slot for the file
create or replace function dz_vid_begin(p_tok text, p_drill text, p_hw text, p_type text, p_size bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; pl dg_players; vid uuid := gen_random_uuid(); ext text; pth text; used bigint;
begin
  a := dg_me(p_tok);
  if a.role <> 'player' or a.status <> 'active' then raise exception 'players_only'; end if;
  select * into pl from dg_players where claimed_by = a.id;
  if pl.id is null then raise exception 'not_claimed'; end if;
  if coalesce(p_size, 0) <= 0 or p_size > 104857600 then raise exception 'too_big'; end if;
  if (select count(*) from dg_videos where account_id = a.id and created_at > now() - interval '1 day') >= 10 then
    raise exception 'too_many';
  end if;
  select coalesce(sum(size), 0) into used from dg_videos where org_id = dg_org() and status in ('uploading','sent');
  if used + p_size > 943718400 then raise exception 'storage_full'; end if;
  ext := case when p_type ilike '%quicktime%' then 'mov' when p_type ilike '%webm%' then 'webm' else 'mp4' end;
  pth := dg_org()::text || '/' || pl.id::text || '/' || vid::text || '.' || ext;
  insert into dg_videos(id, org_id, player_id, account_id, drill, hw_aid, path, size)
    values (vid, dg_org(), pl.id, a.id, left(coalesce(p_drill, ''), 40), left(coalesce(p_hw, ''), 60), pth, p_size);
  return jsonb_build_object('id', vid, 'path', pth);
end $$;

-- player finished uploading
create or replace function dz_vid_sent(p_tok text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a dg_accounts;
begin
  a := dg_me(p_tok);
  update dg_videos set status = 'sent' where id = p_id and account_id = a.id and status = 'uploading';
  if not found then raise exception 'not_found'; end if;
end $$;

-- coach: clips waiting to be watched (plus stale uploads for the function to clean up)
create or replace function dz_vid_list(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; vids jsonb; stale jsonb;
begin
  a := dg_coach(p_tok);
  select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'player_id', v.player_id, 'player_name', p.name, 'num', p.num,
           'drill', v.drill, 'hw', v.hw_aid <> '', 'created_at', v.created_at) order by v.created_at desc), '[]'::jsonb)
    into vids from dg_videos v join dg_players_all p on p.id = v.player_id
    where v.org_id = dg_org() and v.status = 'sent';
  with gone as (delete from dg_videos where org_id = dg_org() and status = 'uploading'
                  and created_at < now() - interval '1 day' returning path)
    select coalesce(jsonb_agg(path), '[]'::jsonb) into stale from gone;
  return jsonb_build_object('videos', vids, 'stale', stale);
end $$;

-- coach: the file to make a 1-hour viewing link for
create or replace function dz_vid_get(p_tok text, p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; pth text;
begin
  a := dg_coach(p_tok);
  select path into pth from dg_videos where id = p_id and org_id = dg_org() and status = 'sent';
  if pth is null then raise exception 'not_found'; end if;
  return pth;
end $$;

-- coach watched it: mark it and hand back the file so the function deletes it
create or replace function dz_vid_seen(p_tok text, p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; pth text;
begin
  a := dg_coach(p_tok);
  update dg_videos set status = 'seen', seen_at = now()
    where id = p_id and org_id = dg_org() and status = 'sent' returning path into pth;
  if pth is null then raise exception 'not_found'; end if;
  return pth;
end $$;

-- only the Edge Function (service role) may call these
revoke execute on function dz_vid_begin(text,text,text,text,bigint), dz_vid_sent(text,uuid), dz_vid_list(text),
  dz_vid_get(text,uuid), dz_vid_seen(text,uuid) from public, anon, authenticated;
grant execute on function dz_vid_begin(text,text,text,text,bigint), dz_vid_sent(text,uuid), dz_vid_list(text),
  dz_vid_get(text,uuid), dz_vid_seen(text,uuid) to service_role;
