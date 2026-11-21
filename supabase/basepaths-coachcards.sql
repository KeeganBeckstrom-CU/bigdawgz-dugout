-- =====================================================================
-- Basepaths: coaches' Dugout Cards are saved to their account
-- (they used to live only on the phone they were opened on).
-- One collection per coach account, the same on every device and team.
--
-- HOW TO RUN: Supabase SQL Editor, after basepaths-orgs.sql. Safe to run again.
-- =====================================================================
create table if not exists dg_coach_cards (
  account_id uuid primary key references dg_users(id) on delete cascade,
  doc jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table dg_coach_cards enable row level security;
revoke all on dg_coach_cards from anon, authenticated;

create or replace function dz_ccards_get(p_tok text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a dg_accounts; d jsonb;
begin
  a := dg_coach(p_tok);
  select doc into d from dg_coach_cards where account_id = a.id;
  return coalesce(d, '{}'::jsonb);
end $$;

create or replace function dz_ccards_save(p_tok text, p_doc jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a dg_accounts;
begin
  a := dg_coach(p_tok);
  if jsonb_typeof(p_doc) <> 'object' then raise exception 'bad_doc'; end if;
  if pg_column_size(p_doc) > 4000000 then raise exception 'too_big'; end if;
  insert into dg_coach_cards(account_id, doc, updated_at) values (a.id, p_doc, now())
    on conflict (account_id) do update set doc = excluded.doc, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

grant execute on function dz_ccards_get(text), dz_ccards_save(text,jsonb) to anon, authenticated;
notify pgrst, 'reload schema';
