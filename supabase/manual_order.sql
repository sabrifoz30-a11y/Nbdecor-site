-- orders typed in by the owner/confirmer (phone, WhatsApp, shop counter)
alter table public.orders add column if not exists source text not null default 'web';

create or replace function public.staff_order(customer jsonb, items jsonb, ship int default null, st text default 'confirmed') returns bigint
language plpgsql security definer set search_path = public as $$
declare oid bigint; tot int := 0; it jsonb; sf jsonb; nm text; store text := public.my_store();
begin
  if public.my_role() not in ('owner','confirmer') then raise exception 'not allowed'; end if;
  if st not in ('new','confirmed') then raise exception 'bad status'; end if;
  if coalesce(trim(customer->>'name'),'') = '' or length(regexp_replace(coalesce(customer->>'phone',''),'\D','','g')) < 9 then raise exception 'missing customer info'; end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 or jsonb_array_length(items) > 300 then raise exception 'bad items'; end if;
  for it in select * from jsonb_array_elements(items) loop
    if not exists (select 1 from public.products p where p.id = it->>'id' and p.store_id = store) then raise exception 'unknown product'; end if;
    tot := tot + greatest(0, coalesce((it->>'price')::int,0)) * greatest(1, coalesce((it->>'qty')::int,1));
  end loop;
  if ship is null then sf := public.ship_fee(customer, store); end if;
  select name into nm from public.profiles where id = auth.uid();
  insert into public.orders(store_id, source, status, customer, items, total, shipping, shipping_company, history, confirmed_by)
  values (store, 'manual', st, customer, items, tot, coalesce(ship, (sf->>'fee')::int, 0),
    coalesce(sf->>'company', (select c->>'name' from public.settings s, jsonb_array_elements(coalesce(s.data->'shipping'->'companies','[]'::jsonb)) c where s.store_id = store and c->>'id' = s.data->'shipping'->>'def')),
    jsonb_build_array(jsonb_build_object('at', now(), 'what', 'manual', 'by', nm)) || case when st = 'confirmed' then jsonb_build_array(jsonb_build_object('at', now(), 'what', 'confirmed', 'by', nm)) else '[]'::jsonb end,
    case when st = 'confirmed' then auth.uid() end)
  returning id into oid;
  return oid;
end $$;
revoke all on function public.staff_order(jsonb, jsonb, int, text) from public, anon;
grant execute on function public.staff_order(jsonb, jsonb, int, text) to authenticated;
CREATE OR REPLACE FUNCTION public.capi_purchase()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare tok text; s jsonb; px text; ph text; body jsonb; rid bigint; nm text;
begin
  if new.source = 'manual' then return new; end if;
  select value into tok from public.secrets where store_id = new.store_id and key = 'fb_capi_token';
  select data into s from public.settings where store_id = new.store_id;
  px := regexp_replace(coalesce(s->>'fbPixel',''), '\D', '', 'g');
  if tok is null or px = '' or coalesce(s->>'fbPixelOn','true') = 'false' then return new; end if;
  ph := regexp_replace(coalesce(new.customer->>'phone',''), '\D', '', 'g');
  if left(ph,2) = '00' then ph := substr(ph,3); end if;
  if left(ph,1) = '0' then ph := '213' || substr(ph,2); end if;
  nm := lower(trim(split_part(coalesce(new.customer->>'name',''), ' ', 1)));
  body := jsonb_build_object('data', jsonb_build_array(jsonb_build_object(
    'event_name','Purchase','event_time', extract(epoch from now())::bigint,'event_id','order-'||new.id,'action_source','website',
    'event_source_url', coalesce(s->>'shopUrl','https://sabrifoz30-a11y.github.io/Nbdecor-site/'),
    'user_data', jsonb_strip_nulls(jsonb_build_object('ph', case when ph<>'' then jsonb_build_array(public.sha(ph)) end, 'fn', case when nm<>'' then jsonb_build_array(public.sha(nm)) end, 'country', jsonb_build_array(public.sha('dz')))),
    'custom_data', jsonb_build_object('value', new.total, 'currency','DZD','order_id', new.id::text,'num_items',(select coalesce(sum((i->>'qty')::int),0) from jsonb_array_elements(new.items) i),
       'content_ids',(select coalesce(jsonb_agg(i->>'ref'),'[]'::jsonb) from jsonb_array_elements(new.items) i),'content_type','product'))));
  if coalesce(s->>'fbTestCode','') <> '' then body := body || jsonb_build_object('test_event_code', s->>'fbTestCode'); end if;
  select net.http_post(url := 'https://graph.facebook.com/v21.0/'||px||'/events?access_token='||tok, body := body, headers := '{"Content-Type":"application/json"}'::jsonb) into rid;
  insert into public.capi_log(store_id, order_id, request_id) values (new.store_id, new.id, rid);
  return new;
exception when others then return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.tiktok_purchase()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare tok text; s jsonb; px text; ph text; body jsonb; rid bigint;
begin
  if new.source = 'manual' then return new; end if;
  select value into tok from public.secrets where store_id = new.store_id and key = 'tt_events_token';
  select data into s from public.settings where store_id = new.store_id;
  px := regexp_replace(coalesce(s->>'ttPixel',''), '[^A-Za-z0-9]', '', 'g');
  if tok is null or px = '' or coalesce(s->>'ttPixelOn','true') = 'false' then return new; end if;
  ph := regexp_replace(coalesce(new.customer->>'phone',''), '\D', '', 'g');
  if left(ph,2) = '00' then ph := substr(ph,3); end if;
  if left(ph,1) = '0' then ph := '213' || substr(ph,2); end if;
  body := jsonb_build_object('event_source','web','event_source_id',px,'data', jsonb_build_array(jsonb_build_object(
    'event','CompletePayment','event_time', extract(epoch from now())::bigint,'event_id','order-'||new.id,
    'user', jsonb_strip_nulls(jsonb_build_object('phone', case when ph<>'' then public.sha('+'||ph) end, 'external_id', case when ph<>'' then public.sha(ph) end)),
    'page', jsonb_build_object('url', coalesce(s->>'shopUrl','https://sabrifoz30-a11y.github.io/Nbdecor-site/')),
    'properties', jsonb_build_object('value', new.total, 'currency','DZD','order_id', new.id::text,'content_type','product',
       'contents',(select coalesce(jsonb_agg(jsonb_build_object('content_id',i->>'ref','content_name',i->>'ref','quantity',coalesce((i->>'qty')::int,1),'price',coalesce((i->>'price')::numeric,0))),'[]'::jsonb) from jsonb_array_elements(new.items) i)))));
  if coalesce(s->>'ttTestCode','') <> '' then body := body || jsonb_build_object('test_event_code', s->>'ttTestCode'); end if;
  select net.http_post(url := 'https://business-api.tiktok.com/open_api/v1.3/event/track/', body := body,
    headers := jsonb_build_object('Content-Type','application/json','Access-Token',tok)) into rid;
  insert into public.capi_log(store_id, order_id, request_id, platform) values (new.store_id, new.id, rid, 'tiktok');
  return new;
exception when others then return new;
end $function$
;
