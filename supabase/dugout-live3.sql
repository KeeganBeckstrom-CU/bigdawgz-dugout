-- =====================================================================
-- Basepaths: Dugout Live v3
--   * Team battles: players are split into two dugouts; the team with the
--     higher average score wins bonus XP for everyone on it
--   * Power-ups: 3 right in a row earns one. Double Down (x2 points on one
--     question) or 50/50 (two wrong answers disappear)
--   * Video round: questions can carry a YouTube clip that plays after
--     the answer is shown
--   * Championship belt: whoever wins a Dugout Live game takes the team's
--     belt; winning again while holding it is a title defense
--
-- HOW TO RUN: Supabase SQL Editor. Run AFTER dugout-live2.sql. Safe to run again.
-- =====================================================================

-- ---------- player columns: team and power-ups ----------
do $$ declare t text;
begin
  t := case when to_regclass('public.dg_live_p_all') is not null then 'dg_live_p_all' else 'dg_live_p' end;
  execute format('alter table %I add column if not exists team int', t);
  execute format('alter table %I add column if not exists pu jsonb not null default %L::jsonb', t, '{}');
  execute format('alter table %I add column if not exists used jsonb', t);
  if t = 'dg_live_p_all' then
    execute 'create or replace view dg_live_p as select * from dg_live_p_all where org_id = dg_org() with local check option';
    execute 'alter view dg_live_p alter column org_id set default dg_org()';
    execute 'alter view dg_live_p alter column score set default 0';
    execute 'alter view dg_live_p alter column streak set default 0';
    execute 'alter view dg_live_p alter column joined_at set default now()';
    execute 'alter view dg_live_p alter column pu set default ''{}''::jsonb';
    execute 'revoke all on dg_live_p from public, anon, authenticated';
  end if;
end $$;

-- ---------- the belt: one per team (org) ----------
create table if not exists dg_belt (
  org_id uuid primary key,
  player uuid,
  name text,
  since timestamptz not null default now(),
  defenses int not null default 0,
  reigns jsonb not null default '[]'::jsonb
);
alter table dg_belt enable row level security;
revoke all on dg_belt from anon, authenticated;

create or replace function dg_belt_get() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when b.player is null then null else jsonb_build_object('player', b.player, 'name', b.name, 'since', b.since, 'defenses', b.defenses) end
  from dg_belt b where b.org_id = dg_org()
$$;
revoke execute on function dg_belt_get() from public, anon, authenticated;

-- ---------- settings: add teams, team XP, power-ups, belt ----------
create or replace function dg_live_cfg3(p jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare base jsonb := dg_live_cfg(p); tn jsonb;
begin
  if base = '{}'::jsonb then return base; end if;
  tn := case when jsonb_typeof(p->'tnames') = 'array' and jsonb_array_length(p->'tnames') = 2
        then jsonb_build_array(left(coalesce(nullif(trim(p->'tnames'->>0),''),'Home'),20), left(coalesce(nullif(trim(p->'tnames'->>1),''),'Visitors'),20))
        else '["Home","Visitors"]'::jsonb end;
  return base || jsonb_build_object(
    'teams', coalesce((p->>'teams')::boolean, false),
    'tnames', tn,
    'teamxp', greatest(0, least(500, coalesce((p->>'teamxp')::int, 50))),
    'power', coalesce((p->>'power')::boolean, true),
    'belt', coalesce((p->>'belt')::boolean, true));
end $$;

create or replace function dz_live_host(p_tok text, p_qs jsonb, p_secs int, p_cfg jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; pn text;
begin
  a := dg_coach(p_tok);
  if jsonb_typeof(p_qs) <> 'array' or jsonb_array_length(p_qs) < 1 or jsonb_array_length(p_qs) > 33 then raise exception 'bad_quiz'; end if;
  update dg_live set phase = 'done' where host = a.id and phase <> 'done';
  delete from dg_live where created_at < now() - interval '7 days';
  loop
    pn := lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
    exit when not exists (select 1 from dg_live where pin = pn and phase <> 'done');
  end loop;
  insert into dg_live(pin, host, qs, secs, cfg) values (pn, a.id, p_qs, greatest(5, least(60, coalesce(p_secs, 20))), dg_live_cfg3(p_cfg));
  return jsonb_build_object('pin', pn);
end $$;

-- ---------- join: late joiners go to the smaller team ----------
create or replace function dz_live_join(p_tok text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; g dg_live; pl dg_players; tm int;
begin
  a := dg_me(p_tok);
  if a.status <> 'active' then raise exception 'not_active'; end if;
  select * into g from dg_live where pin = trim(p_pin) and phase <> 'done' order by created_at desc limit 1;
  if g.id is null then raise exception 'no_game'; end if;
  select * into pl from dg_players where claimed_by = a.id;
  if coalesce((g.cfg->>'teams')::boolean, false) and g.idx >= 0 then
    select case when count(*) filter (where team = 0) <= count(*) filter (where team = 1) then 0 else 1 end into tm from dg_live_p where live = g.id;
  end if;
  insert into dg_live_p(live, acct, name, player, team) values (g.id, a.id, coalesce(pl.name, a.name), pl.id, tm) on conflict (live, acct) do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- is Coach live? also returns the belt holder ----------
create or replace function dz_live_find(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g dg_live;
begin
  perform dg_me(p_tok);
  select * into g from dg_live where phase <> 'done' and created_at > now() - interval '3 hours' order by created_at desc limit 1;
  return jsonb_build_object('pin', g.pin, 'phase', g.phase, 'belt', dg_belt_get());
end $$;

-- ---------- team scores (average per player, so uneven teams stay fair) ----------
create or replace function dg_live_teams(p_live uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('t', t.team, 'n', t.n, 'avg', t.av, 'total', t.tot) order by t.team), '[]'::jsonb)
  from (select team, count(*) n, round(avg(score))::int av, sum(score)::int tot from dg_live_p where live = p_live and team is not null group by team) t
$$;
revoke execute on function dg_live_teams(uuid) from public, anon, authenticated;

-- ---------- awards: places, everyone else, winning team, belt ----------
create or replace function dg_live_award(p_live uuid) returns void
language plpgsql security definer set search_path = public as $$
declare g dg_live; r record; n int; lbl text; pz jsonb; places int; rest int; wh jsonb; wi int; win jsonb;
  ord text[] := array['1st','2nd','3rd','4th','5th']; tw int; tx int; top record; b dg_belt;
begin
  select * into g from dg_live where id = p_live;
  if g.id is null or g.awarded then return; end if;
  if g.cfg is null or g.cfg = '{}'::jsonb then
    for r in select acct, player, score, (rank() over (order by score desc))::int rk from dg_live_p where live = p_live loop
      if r.player is null then continue; end if;
      n := case when r.score > 0 and r.rk = 1 then 150 when r.score > 0 and r.rk = 2 then 100 when r.score > 0 and r.rk = 3 then 75 else 25 end;
      lbl := case when r.score > 0 and r.rk <= 3 then 'Dugout Live: ' || ord[r.rk] || ' place!' else 'Dugout Live: thanks for playing' end;
      insert into dg_inbox(aid, player_id, item) values ('live-' || p_live || '-' || r.acct, r.player, jsonb_build_object('kind', 'coins', 'n', n, 't', lbl, 'at', current_date)) on conflict (aid) do nothing;
    end loop;
    update dg_live set awarded = true where id = p_live;
    return;
  end if;
  places := coalesce((g.cfg->>'places')::int, 0); rest := coalesce((g.cfg->>'rest')::int, 0); wh := g.cfg->'wheel';
  for r in select acct, player, name, score, (rank() over (order by score desc))::int rk from dg_live_p where live = p_live order by score desc, joined_at loop
    if r.player is null then continue; end if;
    if r.score > 0 and r.rk <= places then
      pz := g.cfg->'prizes'->(r.rk - 1);
      lbl := 'Dugout Live: ' || ord[r.rk] || ' place!';
      if pz->>'k' = 'wheel' then
        if win is null then
          wi := floor(random() * jsonb_array_length(wh))::int; win := wh->wi;
          update dg_live set spin = jsonb_build_object('i', wi, 'name', r.name, 'prize', win, 'at', null) where id = p_live;
        end if;
        pz := win; lbl := 'Dugout Live: 1st place! Prize wheel';
      end if;
      if pz->>'k' = 'pack' then
        insert into dg_inbox(aid, player_id, item) values ('live-' || p_live || '-' || r.acct, r.player, jsonb_build_object('kind', 'pack', 'pk', pz->>'pk', 't', lbl, 'at', current_date)) on conflict (aid) do nothing;
      elsif coalesce((pz->>'n')::int, 0) > 0 then
        insert into dg_inbox(aid, player_id, item) values ('live-' || p_live || '-' || r.acct, r.player, jsonb_build_object('kind', 'coins', 'n', (pz->>'n')::int, 't', lbl, 'at', current_date)) on conflict (aid) do nothing;
      end if;
    elsif rest > 0 then
      insert into dg_inbox(aid, player_id, item) values ('live-' || p_live || '-' || r.acct, r.player, jsonb_build_object('kind', 'coins', 'n', rest, 't', 'Dugout Live: thanks for playing', 'at', current_date)) on conflict (aid) do nothing;
    end if;
  end loop;
  -- winning team
  if coalesce((g.cfg->>'teams')::boolean, false) then
    tx := coalesce((g.cfg->>'teamxp')::int, 0);
    select team into tw from dg_live_p where live = p_live and team is not null group by team order by avg(score) desc, sum(score) desc limit 1;
    if tw is not null and tx > 0 and (select count(distinct round(a)) from (select avg(score) a from dg_live_p where live = p_live and team is not null group by team) z) > 1 then
      for r in select acct, player from dg_live_p where live = p_live and team = tw and player is not null loop
        insert into dg_inbox(aid, player_id, item) values ('live-' || p_live || '-' || r.acct || '-team', r.player, jsonb_build_object('kind', 'coins', 'n', tx, 't', 'Dugout Live: your team won!', 'at', current_date)) on conflict (aid) do nothing;
      end loop;
    end if;
  end if;
  -- the belt goes to the winner (ties: first to join)
  if coalesce((g.cfg->>'belt')::boolean, true) then
    select acct, player, name, score into top from dg_live_p where live = p_live and player is not null order by score desc, joined_at limit 1;
    if top.player is not null and top.score > 0 then
      select * into b from dg_belt where org_id = dg_org();
      if b.org_id is null then
        insert into dg_belt(org_id, player, name, since, defenses, reigns) values (dg_org(), top.player, top.name, now(), 0, '[]'::jsonb);
        update dg_live set spin = coalesce(spin, '{}'::jsonb) || jsonb_build_object('belt', jsonb_build_object('name', top.name, 'kind', 'new')) where id = p_live;
      elsif b.player = top.player then
        update dg_belt set defenses = defenses + 1, name = top.name where org_id = dg_org();
        update dg_live set spin = coalesce(spin, '{}'::jsonb) || jsonb_build_object('belt', jsonb_build_object('name', top.name, 'kind', 'defend', 'n', b.defenses + 1)) where id = p_live;
      else
        update dg_belt set reigns = (reigns || jsonb_build_array(jsonb_build_object('name', b.name, 'since', b.since, 'defenses', b.defenses))),
          player = top.player, name = top.name, since = now(), defenses = 0 where org_id = dg_org();
        update dg_live set spin = coalesce(spin, '{}'::jsonb) || jsonb_build_object('belt', jsonb_build_object('name', top.name, 'kind', 'take', 'from', b.name)) where id = p_live;
      end if;
      insert into dg_inbox(aid, player_id, item) values ('live-' || p_live || '-belt', top.player, jsonb_build_object('kind', 'shout', 't', '🏆 You hold the Dugout Live Championship Belt!', 'at', current_date)) on conflict (aid) do nothing;
    end if;
  end if;
  update dg_live set awarded = true where id = p_live;
end $$;
revoke execute on function dg_live_award(uuid) from public, anon, authenticated;

-- ---------- coach moves the game along (start also splits the teams) ----------
create or replace function dz_live_ctl(p_tok text, p_pin text, p_action text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; g dg_live;
begin
  a := dg_coach(p_tok);
  if p_action = 'spin' then
    select * into g from dg_live where pin = p_pin and host = a.id order by created_at desc limit 1;
    if g.id is null then raise exception 'no_game'; end if;
    if g.spin is not null and g.spin ? 'i' and g.spin->>'at' is null then
      update dg_live set spin = spin || jsonb_build_object('at', (extract(epoch from now()) * 1000)::bigint) where id = g.id;
    end if;
    return jsonb_build_object('ok', true);
  end if;
  select * into g from dg_live where pin = p_pin and host = a.id and phase <> 'done' order by created_at desc limit 1;
  if g.id is null then raise exception 'no_game'; end if;
  if p_action in ('start','next') then
    if g.idx = -1 and coalesce((g.cfg->>'teams')::boolean, false) then
      update dg_live_p p set team = x.t from (select acct, ((row_number() over (order by random())) % 2)::int t from dg_live_p where live = g.id) x where p.live = g.id and p.acct = x.acct;
    end if;
    update dg_live_p p set prev_rank = x.rk from (select acct, rank() over (order by score desc) rk from dg_live_p where live = g.id) x where p.live = g.id and p.acct = x.acct;
    if g.idx + 1 >= jsonb_array_length(g.qs) then
      update dg_live set phase = 'done' where id = g.id; perform dg_live_award(g.id);
    else
      update dg_live set idx = g.idx + 1, phase = 'question', q_at = now() where id = g.id;
    end if;
  elsif p_action = 'reveal' and g.phase = 'question' then
    update dg_live set phase = 'reveal' where id = g.id;
  elsif p_action = 'board' then
    update dg_live set phase = 'board' where id = g.id;
  elsif p_action = 'end' then
    update dg_live set phase = 'done' where id = g.id; perform dg_live_award(g.id);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- power-ups ----------
create or replace function dz_live_power(p_tok text, p_pin text, p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; g dg_live; me dg_live_p; n int; q jsonb; wrong int[]; hide int[];
begin
  a := dg_me(p_tok);
  if p_kind not in ('x2','half') then raise exception 'bad_power'; end if;
  select * into g from dg_live where pin = p_pin and phase = 'question' order by created_at desc limit 1;
  if g.id is null then raise exception 'too_late'; end if;
  select * into me from dg_live_p where live = g.id and acct = a.id;
  if me.acct is null then raise exception 'not_joined'; end if;
  if exists (select 1 from dg_live_a where live = g.id and acct = a.id and qi = g.idx) then raise exception 'already_answered'; end if;
  if me.used is not null and (me.used->>'qi')::int = g.idx then raise exception 'one_per_question'; end if;
  n := coalesce((me.pu->>p_kind)::int, 0);
  if n < 1 then raise exception 'no_power'; end if;
  q := g.qs -> g.idx;
  if p_kind = 'half' then
    select array_agg(i) into wrong from (select i from generate_series(0, jsonb_array_length(q->'o') - 1) i where i <> (q->>'a')::int order by random()) z;
    if coalesce(array_length(wrong, 1), 0) < 2 then raise exception 'no_half'; end if;
    hide := wrong[1:least(2, array_length(wrong, 1) - case when jsonb_array_length(q->'o') <= 3 then 1 else 0 end)];
  end if;
  update dg_live_p set pu = pu || jsonb_build_object(p_kind, n - 1), used = jsonb_build_object('qi', g.idx, 'k', p_kind, 'hide', to_jsonb(coalesce(hide, '{}'::int[])))
    where live = g.id and acct = a.id;
  return jsonb_build_object('ok', true, 'hide', to_jsonb(coalesce(hide, '{}'::int[])));
end $$;

-- ---------- answer: Double Down doubles points; streaks of 3 earn power-ups ----------
create or replace function dz_live_answer(p_tok text, p_pin text, p_qi int, p_choice int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; g dg_live; me dg_live_p; el int; ok boolean; pts int := 0; st int; secs int; got text; x2 boolean;
begin
  a := dg_me(p_tok);
  select * into g from dg_live where pin = p_pin and phase <> 'done' order by created_at desc limit 1;
  if g.id is null then raise exception 'no_game'; end if;
  if g.phase <> 'question' or g.idx <> p_qi then raise exception 'too_late'; end if;
  select * into me from dg_live_p where live = g.id and acct = a.id;
  if me.acct is null then raise exception 'not_joined'; end if;
  secs := coalesce((g.qs -> g.idx ->> 's')::int, g.secs);
  el := (extract(epoch from (now() - g.q_at)) * 1000)::int;
  if el > secs * 1000 + 1500 then raise exception 'too_late'; end if;
  el := least(el, secs * 1000);
  ok := p_choice = (g.qs -> g.idx ->> 'a')::int;
  st := case when ok then me.streak + 1 else 0 end;
  x2 := me.used is not null and (me.used->>'qi')::int = g.idx and me.used->>'k' = 'x2';
  if ok then
    pts := round(1000 * (1 - (el::numeric / (secs * 1000)) / 2))::int + least(greatest(st - 1, 0), 5) * 100;
    if x2 then pts := pts * 2; end if;
  end if;
  insert into dg_live_a(live, acct, qi, choice, ms, correct, pts) values (g.id, a.id, p_qi, p_choice, el, ok, pts);
  if ok and st % 3 = 0 and coalesce((g.cfg->>'power')::boolean, false) then
    got := case when random() < .5 then 'x2' else 'half' end;
    update dg_live_p set score = score + pts, streak = st, pu = pu || jsonb_build_object(got, coalesce((pu->>got)::int, 0) + 1, 'new', got) where live = g.id and acct = a.id;
  else
    update dg_live_p set score = score + pts, streak = st where live = g.id and acct = a.id;
  end if;
  return jsonb_build_object('ok', true);
exception when unique_violation then raise exception 'already_answered';
end $$;

-- ---------- state: teams, power-ups, clips, belt ----------
create or replace function dz_live_state(p_tok text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; g dg_live; host boolean; q jsonb; me dg_live_p; my dg_live_a; left_ms int; out jsonb; showans boolean; lim int; secs int; teams boolean;
begin
  a := dg_me(p_tok);
  select * into g from dg_live where pin = p_pin order by created_at desc limit 1;
  if g.id is null then raise exception 'no_game'; end if;
  host := g.host = a.id;
  q := case when g.idx >= 0 then g.qs -> g.idx else null end;
  secs := coalesce((q->>'s')::int, g.secs);
  teams := coalesce((g.cfg->>'teams')::boolean, false);
  showans := g.phase in ('reveal','board','done');
  lim := case when g.phase = 'done' then 10 else 5 end;
  left_ms := case when g.phase = 'question' then greatest(0, secs * 1000 - (extract(epoch from (now() - g.q_at)) * 1000)::int) else 0 end;
  out := jsonb_build_object('pin', g.pin, 'phase', g.phase, 'idx', g.idx, 'total', jsonb_array_length(g.qs), 'secs', secs, 'left_ms', left_ms, 'host', host,
    'q', case when q is null then null else jsonb_build_object('q', q->>'q', 'o', q->'o', 'cat', q->>'cat', 'vid', (q ? 'v')) end,
    'a', case when showans and q is not null then (q->>'a')::int else null end,
    'why', case when showans and q is not null then q->>'why' else null end,
    'clip', case when showans and q ? 'v' then jsonb_build_object('v', q->>'v', 's', q->'vs', 'e', q->'ve', 't', q->>'vt') else null end,
    'count', (select count(*) from dg_live_p where live = g.id),
    'answered', (select count(*) from dg_live_a where live = g.id and qi = g.idx),
    'players', case when g.phase = 'lobby' or host then coalesce((select jsonb_agg(name order by joined_at) from dg_live_p where live = g.id), '[]'::jsonb) else '[]'::jsonb end,
    'dist', case when showans then (select jsonb_build_array(count(*) filter (where choice = 0), count(*) filter (where choice = 1), count(*) filter (where choice = 2), count(*) filter (where choice = 3)) from dg_live_a where live = g.id and qi = g.idx) else null end,
    'board', case when g.phase in ('board','done','reveal') then coalesce((select jsonb_agg(jsonb_build_object('name', x.name, 'score', x.score, 'rank', x.rk, 'up', coalesce(x.prev_rank - x.rk, 0), 'team', x.team) order by x.score desc) from (select name, score, prev_rank, team, rank() over (order by score desc) rk from dg_live_p where live = g.id order by score desc limit lim) x), '[]'::jsonb) else null end,
    'cfg', case when g.cfg = '{}'::jsonb then null else g.cfg - 'wheel' || jsonb_build_object('wheel', g.cfg->'wheel') end,
    'teams', case when teams and g.idx >= 0 then dg_live_teams(g.id) else null end,
    'spin', case when g.phase = 'done' then g.spin else null end,
    'belt', case when g.phase in ('lobby','done') then dg_belt_get() else null end,
    'fans', (select count(*) from jsonb_object_keys(g.fans)),
    'watching', g.fans ? a.id::text);
  select * into me from dg_live_p where live = g.id and acct = a.id;
  if me.acct is not null then
    select * into my from dg_live_a where live = g.id and acct = a.id and qi = g.idx;
    out := out || jsonb_build_object('me', jsonb_build_object('name', me.name, 'score', me.score, 'streak', me.streak, 'team', me.team,
      'rank', (select count(*) + 1 from dg_live_p where live = g.id and score > me.score),
      'answered', my.acct is not null, 'choice', my.choice,
      'pu', me.pu - 'new', 'newpu', me.pu->>'new',
      'used', case when me.used is not null and (me.used->>'qi')::int = g.idx then me.used else null end,
      'correct', case when showans then my.correct else null end, 'pts', case when showans then my.pts else null end));
  end if;
  return out;
end $$;

-- clear the "you just earned" flag once the player has seen it
create or replace function dz_live_seen(p_tok text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; g dg_live;
begin
  a := dg_me(p_tok);
  select * into g from dg_live where pin = p_pin order by created_at desc limit 1;
  if g.id is null then raise exception 'no_game'; end if;
  update dg_live_p set pu = pu - 'new' where live = g.id and acct = a.id;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function dz_live_host(text,jsonb,int,jsonb), dz_live_join(text,text), dz_live_find(text), dz_live_ctl(text,text,text),
  dz_live_power(text,text,text), dz_live_answer(text,text,int,int), dz_live_state(text,text), dz_live_seen(text,text) to anon, authenticated;

notify pgrst, 'reload schema';
