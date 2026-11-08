-- Meta Conversions API: secret token stored server-side, Purchase sent on each new order
create extension if not exists pg_net;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.secrets (key text primary key, value text not null, updated_at timestamptz default now());
alter table public.secrets enable row level security;  -- no policies: nobody can read or write it directly
revoke all on public.secrets from anon, authenticated;

create or replace function public.set_secret(k text, v text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if k not in ('fb_capi_token') then raise exception 'unknown key'; end if;
  if v is null or length(trim(v)) = 0 then delete from public.secrets where key = k;
  else insert into public.secrets(key, value, updated_at) values (k, trim(v), now()) on conflict (key) do update set value = excluded.value, updated_at = now(); end if;
end $$;
create or replace function public.secret_status(k text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  select updated_at, right(value, 4) as tail into r from public.secrets where key = k;
  if not found then return jsonb_build_object('set', false); end if;
  return jsonb_build_object('set', true, 'updated_at', r.updated_at, 'tail', r.tail);
end $$;
revoke all on function public.set_secret(text,text) from public, anon;
revoke all on function public.secret_status(text) from public, anon;
grant execute on function public.set_secret(text,text) to authenticated;
grant execute on function public.secret_status(text) to authenticated;

create or replace function public.sha(t text) returns text language sql immutable as $$ select encode(extensions.digest(convert_to(t,'UTF8'),'sha256'),'hex') $$;

create table if not exists public.capi_log (id bigserial primary key, order_id bigint, request_id bigint, created_at timestamptz default now());
alter table public.capi_log enable row level security;
drop policy if exists "owner reads capi log" on public.capi_log;
create policy "owner reads capi log" on public.capi_log for select using (public.my_role()='owner');

create or replace function public.capi_purchase() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare tok text; s jsonb; px text; ph text; body jsonb; rid bigint; nm text;
begin
  select value into tok from public.secrets where key = 'fb_capi_token';
  select data into s from public.settings where id = 1;
  px := regexp_replace(coalesce(s->>'fbPixel',''), '\D', '', 'g');
  if tok is null or px = '' or coalesce(s->>'fbPixelOn','true') = 'false' then return new; end if;
  ph := regexp_replace(coalesce(new.customer->>'phone',''), '\D', '', 'g');
  if left(ph,2) = '00' then ph := substr(ph,3); end if;
  if left(ph,1) = '0' then ph := '213' || substr(ph,2); end if;
  nm := lower(trim(split_part(coalesce(new.customer->>'name',''), ' ', 1)));
  body := jsonb_build_object('data', jsonb_build_array(jsonb_build_object(
    'event_name','Purchase','event_time', extract(epoch from now())::bigint,'event_id','order-'||new.id,'action_source','website',
    'event_source_url', 'https://sabrifoz30-a11y.github.io/Nbdecor-site/',
    'user_data', jsonb_strip_nulls(jsonb_build_object('ph', case when ph<>'' then jsonb_build_array(public.sha(ph)) end, 'fn', case when nm<>'' then jsonb_build_array(public.sha(nm)) end, 'country', jsonb_build_array(public.sha('dz')))),
    'custom_data', jsonb_build_object('value', new.total, 'currency','DZD','order_id', new.id::text,'num_items',(select coalesce(sum((i->>'qty')::int),0) from jsonb_array_elements(new.items) i),
       'content_ids',(select coalesce(jsonb_agg(i->>'ref'),'[]'::jsonb) from jsonb_array_elements(new.items) i),'content_type','product'))));
  if coalesce(s->>'fbTestCode','') <> '' then body := body || jsonb_build_object('test_event_code', s->>'fbTestCode'); end if;
  select net.http_post(url := 'https://graph.facebook.com/v21.0/'||px||'/events?access_token='||tok, body := body, headers := '{"Content-Type":"application/json"}'::jsonb) into rid;
  insert into public.capi_log(order_id, request_id) values (new.id, rid);
  return new;
exception when others then return new;  -- never block an order because of tracking
end $$;
drop trigger if exists orders_capi on public.orders;
create trigger orders_capi after insert on public.orders for each row execute function public.capi_purchase();

create or replace function public.capi_last() returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  select jsonb_build_object('order_id', l.order_id, 'at', l.created_at, 'status', h.status_code, 'body', left(h.content, 300), 'error', h.error_msg)
    into r from public.capi_log l left join net._http_response h on h.id = l.request_id order by l.id desc limit 1;
  return coalesce(r, '{}'::jsonb);
end $$;
revoke all on function public.capi_last() from public, anon;
grant execute on function public.capi_last() to authenticated;
