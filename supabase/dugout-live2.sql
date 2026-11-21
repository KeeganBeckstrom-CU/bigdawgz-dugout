-- =====================================================================
-- Basepaths: Dugout Live v2
--   * the coach picks how many places win and what each place gets
--     (prize wheel, a pack, or XP), plus XP for everyone else
--   * prize wheel for 1st place: the server picks the prize, every
--     screen spins to it
--   * parents (and coaches who aren't hosting) can watch a game live
--
-- HOW TO RUN: Supabase dashboard > SQL Editor > New query > paste all of
-- this > Run. Run it AFTER dugout-live.sql and basepaths-orgs.sql.
-- Safe to run again.
-- =====================================================================

-- ---------- new columns: the game's settings, the wheel spin, who's watching ----------
do $$ declare t text;
begin
  t := case when to_regclass('public.dg_live_all') is not null then 'dg_live_all' else 'dg_live' end;
  execute format('alter table %I add column if not exists cfg jsonb not null default %L::jsonb', t, '{}');
  execute format('alter table %I add column if not exists spin jsonb', t);
  execute format('alter table %I add column if not exists fans jsonb not null default %L::jsonb', t, '{}');
  if t = 'dg_live_all' then
    -- the per-team view picks up the new columns (they are added at the end)
    execute 'create or replace view dg_live as select * from dg_live_all where org_id = dg_org() with local check option';
    execute 'alter view dg_live alter column org_id set default dg_org()';
    execute 'alter view dg_live alter column cfg set default ''{}''::jsonb';
    execute 'alter view dg_live alter column fans set default ''{}''::jsonb';
    execute 'alter view dg_live alter column id set default gen_random_uuid()';
    execute 'alter view dg_live alter column secs set default 20';
    execute 'alter view dg_live alter column idx set default -1';
    execute 'alter view dg_live alter column phase set default ''lobby''';
    execute 'alter view dg_live alter column awarded set default false';
    execute 'alter view dg_live alter column created_at set default now()';
    execute 'revoke all on dg_live from public, anon, authenticated';
  end if;
end $$;

-- ---------- settings, cleaned up so a game can never hand out silly prizes ----------
-- cfg: { places: 0-5,
--        prizes: [ {k:'wheel'} | {k:'pack', pk:'allstar'} | {k:'xp', n:150} , ... ]   (wheel only for 1st)
--        rest: XP for everyone else who played (0-100),
--        wheel: [ {k:'pack', pk, lbl} | {k:'xp', n, lbl}, ... ]  (2-12 slices),
--        fans: true/false  (parents can watch) }
create or replace function dg_live_cfg(p jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare packs text[] := array['rookie','allstar','heat','slam','series','hof','galaxy'];
  places int; rest int; pr jsonb := '[]'::jsonb; wh jsonb := '[]'::jsonb; x jsonb; i int; k text;
begin
  if p is null or jsonb_typeof(p) <> 'object' then return '{}'::jsonb; end if;
  places := greatest(0, least(5, coalesce((p->>'places')::int, 3)));
  rest := greatest(0, least(100, coalesce((p->>'rest')::int, 25)));
  for i in 0 .. places - 1 loop
    x := coalesce(p->'prizes'->i, '{}'::jsonb); k := x->>'k';
    if k = 'wheel' and i = 0 then pr := pr || jsonb_build_array(jsonb_build_object('k','wheel'));
    elsif k = 'pack' and (x->>'pk') = any(packs) then pr := pr || jsonb_build_array(jsonb_build_object('k','pack','pk',x->>'pk'));
    else pr := pr || jsonb_build_array(jsonb_build_object('k','xp','n',greatest(0, least(2000, coalesce((x->>'n')::int, 50)))));
    end if;
  end loop;
  if jsonb_typeof(p->'wheel') = 'array' then
    for x in select * from jsonb_array_elements(p->'wheel') limit 12 loop
      if x->>'k' = 'pack' and (x->>'pk') = any(packs) then
        wh := wh || jsonb_build_array(jsonb_build_object('k','pack','pk',x->>'pk','lbl',left(coalesce(x->>'lbl',''),40)));
      elsif x->>'k' = 'xp' then
        wh := wh || jsonb_build_array(jsonb_build_object('k','xp','n',greatest(0, least(2000, coalesce((x->>'n')::int, 100))),'lbl',left(coalesce(x->>'lbl',''),40)));
      end if;
    end loop;
  end if;
  if jsonb_array_length(wh) < 2 then
    wh := '[{"k":"pack","pk":"slam","lbl":"Grand Slam pack"},{"k":"xp","n":500,"lbl":"500 XP"},{"k":"pack","pk":"series","lbl":"World Series Vault"},{"k":"xp","n":300,"lbl":"300 XP"},{"k":"pack","pk":"heat","lbl":"Bullpen Heat pack"},{"k":"pack","pk":"hof","lbl":"Hall of Fame Vault"}]'::jsonb;
  end if;
  return jsonb_build_object('places', places, 'prizes', pr, 'rest', rest, 'wheel', wh, 'fans', coalesce((p->>'fans')::boolean, true));
end $$;

-- ---------- coach starts a game with settings ----------
create or replace function dz_live_host(p_tok text, p_qs jsonb, p_secs int, p_cfg jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; pn text;
begin
  a := dg_coach(p_tok);
  if jsonb_typeof(p_qs) <> 'array' or jsonb_array_length(p_qs) < 1 or jsonb_array_length(p_qs) > 30 then raise exception 'bad_quiz'; end if;
  update dg_live set phase = 'done' where host = a.id and phase <> 'done';
  delete from dg_live where created_at < now() - interval '7 days';
  loop
    pn := lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
    exit when not exists (select 1 from dg_live where pin = pn and phase <> 'done');
  end loop;
  insert into dg_live(pin, host, qs, secs, cfg) values (pn, a.id, p_qs, greatest(5, least(60, coalesce(p_secs, 20))), dg_live_cfg(p_cfg));
  return jsonb_build_object('pin', pn);
end $$;

-- ---------- a parent (or another coach) watches without playing ----------
create or replace function dz_live_watch(p_tok text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; g dg_live;
begin
  a := dg_me(p_tok);
  if a.status <> 'active' then raise exception 'not_active'; end if;
  select * into g from dg_live where pin = trim(p_pin) and phase <> 'done' order by created_at desc limit 1;
  if g.id is null then raise exception 'no_game'; end if;
  if coalesce((g.cfg->>'fans')::boolean, true) = false and a.role <> 'coach' then raise exception 'no_fans'; end if;
  update dg_live set fans = fans || jsonb_build_object(a.id::text, a.name) where id = g.id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- end of game: prizes ----------
create or replace function dg_live_award(p_live uuid) returns void
language plpgsql security definer set search_path = public as $$
declare g dg_live; r record; n int; lbl text; pz jsonb; places int; rest int; wh jsonb; wi int; win jsonb; first boolean := true;
  ord text[] := array['1st','2nd','3rd','4th','5th'];
begin
  select * into g from dg_live where id = p_live;
  if g.id is null or g.awarded then return; end if;
  if g.cfg is null or g.cfg = '{}'::jsonb then
    -- old games: 150 / 100 / 75, 25 for everyone else
    for r in select acct, player, score, rank() over (order by score desc) rk from dg_live_p where live = p_live loop
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
      pz := g.cfg->'prizes'->((r.rk - 1)::int);
      lbl := 'Dugout Live: ' || ord[r.rk] || ' place!';
      if pz->>'k' = 'wheel' then
        -- the server spins: one result for the winner (ties at 1st share it)
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
  update dg_live set awarded = true where id = p_live;
end $$;
revoke execute on function dg_live_award(uuid) from public, anon, authenticated;

-- ---------- coach moves the game along: start / reveal / board / next / end / spin ----------
create or replace function dz_live_ctl(p_tok text, p_pin text, p_action text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; g dg_live;
begin
  a := dg_coach(p_tok);
  if p_action = 'spin' then
    -- the wheel is spun after the game ends; the prize was already picked and sent
    select * into g from dg_live where pin = p_pin and host = a.id order by created_at desc limit 1;
    if g.id is null then raise exception 'no_game'; end if;
    if g.spin is not null and g.spin->>'at' is null then
      update dg_live set spin = spin || jsonb_build_object('at', (extract(epoch from now()) * 1000)::bigint) where id = g.id;
    end if;
    return jsonb_build_object('ok', true);
  end if;
  select * into g from dg_live where pin = p_pin and host = a.id and phase <> 'done' order by created_at desc limit 1;
  if g.id is null then raise exception 'no_game'; end if;
  if p_action in ('start','next') then
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

-- ---------- what everyone's screen shows (players, the host, and people watching) ----------
create or replace function dz_live_state(p_tok text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; g dg_live; host boolean; q jsonb; me dg_live_p; my dg_live_a; left_ms int; out jsonb; showans boolean; lim int;
begin
  a := dg_me(p_tok);
  select * into g from dg_live where pin = p_pin order by created_at desc limit 1;
  if g.id is null then raise exception 'no_game'; end if;
  host := g.host = a.id;
  q := case when g.idx >= 0 then g.qs -> g.idx else null end;
  showans := g.phase in ('reveal','board','done');
  lim := case when g.phase = 'done' then 10 else 5 end;
  left_ms := case when g.phase = 'question' then greatest(0, g.secs * 1000 - (extract(epoch from (now() - g.q_at)) * 1000)::int) else 0 end;
  out := jsonb_build_object('pin', g.pin, 'phase', g.phase, 'idx', g.idx, 'total', jsonb_array_length(g.qs), 'secs', g.secs, 'left_ms', left_ms, 'host', host,
    'q', case when q is null then null else jsonb_build_object('q', q->>'q', 'o', q->'o', 'cat', q->>'cat') end,
    'a', case when showans and q is not null then (q->>'a')::int else null end,
    'why', case when showans and q is not null then q->>'why' else null end,
    'count', (select count(*) from dg_live_p where live = g.id),
    'answered', (select count(*) from dg_live_a where live = g.id and qi = g.idx),
    'players', case when g.phase = 'lobby' or host then coalesce((select jsonb_agg(name order by joined_at) from dg_live_p where live = g.id), '[]'::jsonb) else '[]'::jsonb end,
    'dist', case when showans then (select jsonb_build_array(count(*) filter (where choice = 0), count(*) filter (where choice = 1), count(*) filter (where choice = 2), count(*) filter (where choice = 3)) from dg_live_a where live = g.id and qi = g.idx) else null end,
    'board', case when g.phase in ('board','done','reveal') then coalesce((select jsonb_agg(jsonb_build_object('name', x.name, 'score', x.score, 'rank', x.rk, 'up', coalesce(x.prev_rank - x.rk, 0)) order by x.score desc) from (select name, score, prev_rank, rank() over (order by score desc) rk from dg_live_p where live = g.id order by score desc limit lim) x), '[]'::jsonb) else null end,
    'cfg', case when g.cfg = '{}'::jsonb then null else jsonb_build_object('places', g.cfg->'places', 'prizes', g.cfg->'prizes', 'rest', g.cfg->'rest', 'wheel', g.cfg->'wheel', 'fans', g.cfg->'fans') end,
    'spin', case when g.phase = 'done' then g.spin else null end,
    'fans', (select count(*) from jsonb_object_keys(g.fans)),
    'watching', g.fans ? a.id::text);
  select * into me from dg_live_p where live = g.id and acct = a.id;
  if me.acct is not null then
    select * into my from dg_live_a where live = g.id and acct = a.id and qi = g.idx;
    out := out || jsonb_build_object('me', jsonb_build_object('name', me.name, 'score', me.score, 'streak', me.streak,
      'rank', (select count(*) + 1 from dg_live_p where live = g.id and score > me.score),
      'answered', my.acct is not null, 'choice', my.choice,
      'correct', case when showans then my.correct else null end, 'pts', case when showans then my.pts else null end));
  end if;
  return out;
end $$;

grant execute on function dz_live_host(text,jsonb,int,jsonb), dz_live_watch(text,text), dz_live_ctl(text,text,text), dz_live_state(text,text) to anon, authenticated;

notify pgrst, 'reload schema';
