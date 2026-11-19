-- Visitor tracking: the shop sends what each visitor does (anonymous device id + session id); the owner sees the
-- funnel, the sources, the products and each visit step by step. Staff devices are not tracked.
create table if not exists public.shop_events(
  id bigserial primary key, store_id text not null, vid text not null, sid text not null,
  ev text not null, data jsonb, at timestamptz not null default now());
create index if not exists shop_events_store_at on public.shop_events(store_id, at desc);
create index if not exists shop_events_sid on public.shop_events(store_id, sid, at);
alter table public.shop_events enable row level security;
drop policy if exists "owner reads events" on public.shop_events;
create policy "owner reads events" on public.shop_events for select using (store_id = public.my_store() and public.my_role() = 'owner');

create or replace function public.track(store text, vid text, sid text, evs jsonb) returns void language plpgsql security definer set search_path = public as $$
begin
  if store !~ '^[a-z0-9-]{1,40}$' or vid !~ '^[a-z0-9]{8,40}$' or sid !~ '^[a-z0-9]{8,40}$' then return; end if;
  if jsonb_typeof(evs) <> 'array' or jsonb_array_length(evs) = 0 or jsonb_array_length(evs) > 40 or length(evs::text) > 20000 then return; end if;
  if not exists (select 1 from public.stores where id = store) then return; end if;
  -- simple flood guard: at most 600 events per visit
  if (select count(*) from public.shop_events e where e.store_id = store and e.sid = track.sid) > 600 then return; end if;
  insert into public.shop_events(store_id, vid, sid, ev, data, at)
  select store, vid, sid, x->>'e', case when jsonb_typeof(x->'d') = 'object' then x->'d' end,
         case when (x->>'t') ~ '^[0-9]{12,14}$' and abs((x->>'t')::bigint/1000 - extract(epoch from now())) < 600 then to_timestamp((x->>'t')::bigint/1000.0) else now() end
  from jsonb_array_elements(evs) x
  where x->>'e' in ('visit','cat','search','view','add','cart','fill','send','order','fail','howto','help','leave','shop','dl','pick','wa');
end $$;
revoke all on function public.track(text, text, text, jsonb) from public;
grant execute on function public.track(text, text, text, jsonb) to anon, authenticated;

-- summary for a period: funnel (distinct visitors per step), sources, products, devices
create or replace function public.stats_summary(since timestamptz, till timestamptz default now()) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st text := public.my_store(); r jsonb;
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  with e as (select * from public.shop_events where store_id = st and at >= since and at <= till)
  select jsonb_build_object(
    'funnel', jsonb_build_object(
      'visit', (select count(distinct vid) from e),
      'view', (select count(distinct vid) from e where ev = 'view'),
      'add', (select count(distinct vid) from e where ev = 'add'),
      'cart', (select count(distinct vid) from e where ev = 'cart'),
      'fill', (select count(distinct vid) from e where ev = 'fill'),
      'send', (select count(distinct vid) from e where ev = 'send'),
      'order', (select count(distinct vid) from e where ev = 'order')),
    'visits', (select count(distinct sid) from e),
    'sources', coalesce((select jsonb_agg(jsonb_build_object('s', s, 'n', n) order by n desc) from
        (select coalesce(data->>'src','مباشر') s, count(distinct vid) n from e where ev = 'visit' group by 1) x), '[]'),
    'devices', coalesce((select jsonb_agg(jsonb_build_object('s', s, 'n', n) order by n desc) from
        (select coalesce(data->>'dev','?') s, count(distinct vid) n from e where ev = 'visit' group by 1) x), '[]'),
    'products', coalesce((select jsonb_agg(jsonb_build_object('ref', ref, 'v', v, 'a', a) order by v desc, a desc) from
        (select data->>'ref' ref, count(distinct vid) filter (where ev = 'view') v, count(distinct vid) filter (where ev = 'add') a
         from e where ev in ('view','add') and data ? 'ref' group by 1 order by 2 desc, 3 desc limit 30) x), '[]'),
    'errors', coalesce((select jsonb_agg(jsonb_build_object('k', k, 'n', n) order by n desc) from
        (select k, count(distinct vid) n from e, jsonb_array_elements_text(coalesce(data->'errs','[]'::jsonb)) k where ev = 'send' group by 1) x), '[]'),
    'avgsec', (select round(avg(m)) from (select max((data->>'sec')::numeric) m from e where ev = 'leave' and (data->>'sec') ~ '^[0-9]+$' group by sid) x)
  ) into r;
  return r;
end $$;

-- the latest visits, each with its steps in order
create or replace function public.stats_sessions(since timestamptz, only_cart boolean default false, lim int default 60) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st text := public.my_store(); r jsonb;
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  with s as (
    select sid, min(at) a0, max(at) a1, max(vid) vid from public.shop_events where store_id = st and at >= since group by sid
    having not only_cart or bool_or(ev in ('add','cart'))
    order by max(at) desc limit least(greatest(lim,1),200))
  select coalesce(jsonb_agg(jsonb_build_object('sid', s.sid, 'vid', s.vid, 'a0', s.a0, 'a1', s.a1,
      'back', (select count(distinct x.sid) from public.shop_events x where x.store_id = st and x.vid = s.vid and x.at < s.a0) ,
      'evs', (select jsonb_agg(jsonb_build_object('e', ev, 'd', data, 't', at) order by at, id) from public.shop_events x where x.store_id = st and x.sid = s.sid))
    order by s.a1 desc), '[]') into r from s;
  return r;
end $$;
revoke all on function public.stats_summary(timestamptz, timestamptz) from public, anon;
revoke all on function public.stats_sessions(timestamptz, boolean, int) from public, anon;
grant execute on function public.stats_summary(timestamptz, timestamptz) to authenticated;
grant execute on function public.stats_sessions(timestamptz, boolean, int) to authenticated;
