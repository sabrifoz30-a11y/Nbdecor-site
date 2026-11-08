-- TikTok Events API: hidden token, CompletePayment sent from the server on each new order
create or replace function public.set_secret(k text, v text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if k not in ('fb_capi_token','tt_events_token') then raise exception 'unknown key'; end if;
  if v is null or length(trim(v)) = 0 then delete from public.secrets where key = k;
  else insert into public.secrets(key, value, updated_at) values (k, trim(v), now()) on conflict (key) do update set value = excluded.value, updated_at = now(); end if;
end $$;
alter table public.capi_log add column if not exists platform text not null default 'meta';

create or replace function public.tiktok_purchase() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare tok text; s jsonb; px text; ph text; body jsonb; rid bigint;
begin
  select value into tok from public.secrets where key = 'tt_events_token';
  select data into s from public.settings where id = 1;
  px := regexp_replace(coalesce(s->>'ttPixel',''), '[^A-Za-z0-9]', '', 'g');
  if tok is null or px = '' or coalesce(s->>'ttPixelOn','true') = 'false' then return new; end if;
  ph := regexp_replace(coalesce(new.customer->>'phone',''), '\D', '', 'g');
  if left(ph,2) = '00' then ph := substr(ph,3); end if;
  if left(ph,1) = '0' then ph := '213' || substr(ph,2); end if;
  body := jsonb_build_object('event_source','web','event_source_id',px,'data', jsonb_build_array(jsonb_build_object(
    'event','CompletePayment','event_time', extract(epoch from now())::bigint,'event_id','order-'||new.id,
    'user', jsonb_strip_nulls(jsonb_build_object('phone', case when ph<>'' then public.sha('+'||ph) end, 'external_id', case when ph<>'' then public.sha(ph) end)),
    'page', jsonb_build_object('url','https://sabrifoz30-a11y.github.io/Nbdecor-site/'),
    'properties', jsonb_build_object('value', new.total, 'currency','DZD','order_id', new.id::text,'content_type','product',
       'contents',(select coalesce(jsonb_agg(jsonb_build_object('content_id',i->>'ref','content_name',i->>'ref','quantity',coalesce((i->>'qty')::int,1),'price',coalesce((i->>'price')::numeric,0))),'[]'::jsonb) from jsonb_array_elements(new.items) i)))));
  if coalesce(s->>'ttTestCode','') <> '' then body := body || jsonb_build_object('test_event_code', s->>'ttTestCode'); end if;
  select net.http_post(url := 'https://business-api.tiktok.com/open_api/v1.3/event/track/', body := body,
    headers := jsonb_build_object('Content-Type','application/json','Access-Token',tok)) into rid;
  insert into public.capi_log(order_id, request_id, platform) values (new.id, rid, 'tiktok');
  return new;
exception when others then return new;
end $$;
drop trigger if exists orders_tiktok on public.orders;
create trigger orders_tiktok after insert on public.orders for each row execute function public.tiktok_purchase();

create or replace function public.capi_last(p text default 'meta') returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  select jsonb_build_object('order_id', l.order_id, 'at', l.created_at, 'status', h.status_code, 'body', left(h.content, 300), 'error', h.error_msg)
    into r from public.capi_log l left join net._http_response h on h.id = l.request_id where l.platform = p order by l.id desc limit 1;
  return coalesce(r, '{}'::jsonb);
end $$;
drop function if exists public.capi_last();
revoke all on function public.capi_last(text) from public, anon;
grant execute on function public.capi_last(text) to authenticated;
