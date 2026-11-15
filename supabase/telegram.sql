-- Telegram notifications: every new order from the shop is posted to the store's Telegram group by its own bot.
create or replace function public.set_secret(k text, v text) returns void language plpgsql security definer set search_path = public as $$
declare st text := public.my_store();
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if not (k in ('fb_capi_token','tt_events_token','tg_bot_token') or k ~ '^carrier:[a-z0-9_-]{1,40}$') then raise exception 'unknown key'; end if;
  if v is null or length(trim(v)) = 0 then delete from public.secrets where store_id = st and key = k;
  else insert into public.secrets(store_id, key, value, updated_at) values (st, k, trim(v), now()) on conflict (store_id, key) do update set value = excluded.value, updated_at = now(); end if;
end $$;

create table if not exists public.tg_requests(rid bigint primary key, store_id text not null, kind text, created_at timestamptz default now());
alter table public.tg_requests enable row level security;

create or replace function public.tg_post(st text, method text, body jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare tok text; rid bigint;
begin
  select value into tok from public.secrets where store_id = st and key = 'tg_bot_token';
  if tok is null or tok !~ '^[0-9]+:[A-Za-z0-9_-]+$' then return null; end if;
  select net.http_post(url := 'https://api.telegram.org/bot'||tok||'/'||method, body := body,
    headers := '{"Content-Type":"application/json"}'::jsonb, timeout_milliseconds := 20000) into rid;
  return rid;
end $$;
revoke all on function public.tg_post(text, text, jsonb) from public, anon, authenticated;

create or replace function public.tg_money(x numeric) returns text language sql immutable as $$
  select replace(to_char(coalesce(x,0), 'FM999,999,999'), ',', ' ')||' دج' $$;

create or replace function public.tg_order_text(o public.orders) returns text language plpgsql stable set search_path = public as $$
declare cu jsonb := o.customer; t text;
begin
  t := '🌸 طلبية جديدة #'||o.id||E'\n\n'||
       '👤 '||coalesce(cu->>'name','')||E'\n'||
       '📞 '||coalesce(cu->>'phone','')||E'\n'||
       '📍 '||coalesce(cu->>'wilaya','')||coalesce(' · '||nullif(coalesce(cu->>'commune_ar', cu->>'commune'),''),'')||E'\n'||
       '🚚 '||case when cu->>'delivery' = 'مكتب' then 'مكتب التوصيل' else 'إلى المنزل' end||
       coalesce(E'\n🏠 '||nullif(trim(cu->>'address'),''),'')||E'\n\n'||
       '🛒 المنتجات:'||E'\n'||
       coalesce((select string_agg('• '||coalesce(i->>'ref','')||' × '||coalesce(i->>'qty','1')||
           coalesce(' ('||nullif((select string_agg(v #>> '{}', ' · ') from jsonb_array_elements(coalesce(i->'variant','[]'::jsonb)) v),'')||')','')||
           ' = '||public.tg_money(coalesce((i->>'price')::numeric,0)*coalesce((i->>'qty')::int,1))||
           coalesce(E'\n   ✏️ '||nullif(trim(i->>'note'),''),''), E'\n')
         from jsonb_array_elements(coalesce(o.items,'[]'::jsonb)) i),'')||E'\n\n'||
       '💰 المنتجات: '||public.tg_money(o.total)||
       case when coalesce(o.shipping,0) > 0 then E'\n🚚 التوصيل: '||public.tg_money(o.shipping)||E'\n✅ الإجمالي: '||public.tg_money(coalesce(o.total,0)+o.shipping) else '' end||
       coalesce(E'\n📝 '||nullif(trim(cu->>'notes'),''),'')||E'\n\n'||
       '🔗 https://styledecordz.store/staff.html';
  return left(t, 4000);
end $$;

create or replace function public.tg_new_order() returns trigger language plpgsql security definer set search_path = public as $$
declare s jsonb;
begin
  if coalesce(new.source,'') = 'manual' then return new; end if;
  select data into s from public.settings where store_id = new.store_id;
  if coalesce(s->>'tgChat','') = '' or coalesce(s->>'tgOn','true') = 'false' then return new; end if;
  perform public.tg_post(new.store_id, 'sendMessage', jsonb_build_object('chat_id', s->>'tgChat', 'text', public.tg_order_text(new), 'disable_web_page_preview', true));
  return new;
exception when others then return new;  -- never block an order because of Telegram
end $$;
drop trigger if exists orders_telegram on public.orders;
create trigger orders_telegram after insert on public.orders for each row execute function public.tg_new_order();

-- owner tools: find the groups the bot was added to, send a test message, read a request's result
create or replace function public.tg_discover() returns bigint language plpgsql security definer set search_path = public as $$
declare st text := public.my_store(); rid bigint;
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  rid := public.tg_post(st, 'getUpdates', jsonb_build_object('limit', 100, 'allowed_updates', jsonb_build_array('message','my_chat_member','channel_post')));
  if rid is null then raise exception 'no token'; end if;
  insert into public.tg_requests(rid, store_id, kind) values (rid, st, 'discover');
  return rid;
end $$;

create or replace function public.tg_test() returns bigint language plpgsql security definer set search_path = public as $$
declare st text := public.my_store(); s jsonb; rid bigint;
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  select data into s from public.settings where store_id = st;
  if coalesce(s->>'tgChat','') = '' then raise exception 'no chat'; end if;
  rid := public.tg_post(st, 'sendMessage', jsonb_build_object('chat_id', s->>'tgChat', 'text', '✅ تم ربط المجموعة بالمتجر. ستصل هنا كل طلبية جديدة من الموقع.'));
  if rid is null then raise exception 'no token'; end if;
  insert into public.tg_requests(rid, store_id, kind) values (rid, st, 'test');
  return rid;
end $$;

create or replace function public.tg_result(rid bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare q public.tg_requests; r record; j jsonb; chats jsonb;
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  select * into q from public.tg_requests where tg_requests.rid = tg_result.rid and store_id = public.my_store();
  if not found then raise exception 'unknown request'; end if;
  select status_code, content, error_msg into r from net._http_response where id = q.rid;
  if not found then return jsonb_build_object('done', false); end if;
  begin j := r.content::jsonb; exception when others then j := null; end;
  if coalesce((j->>'ok')::boolean, false) is not true then
    return jsonb_build_object('done', true, 'ok', false, 'status', r.status_code, 'error', coalesce(j->>'description', r.error_msg, ''));
  end if;
  if q.kind = 'discover' then
    select coalesce(jsonb_agg(distinct jsonb_build_object('id', c->>'id', 'title', coalesce(c->>'title', c->>'first_name', ''), 'type', c->>'type')), '[]'::jsonb) into chats
      from jsonb_array_elements(j->'result') u, lateral (select coalesce(u->'message'->'chat', u->'my_chat_member'->'chat', u->'channel_post'->'chat') c) x
      where c is not null and c->>'type' in ('group','supergroup','channel');
    return jsonb_build_object('done', true, 'ok', true, 'chats', chats);
  end if;
  return jsonb_build_object('done', true, 'ok', true);
end $$;
revoke all on function public.tg_discover() from public, anon;
revoke all on function public.tg_test() from public, anon;
revoke all on function public.tg_result(bigint) from public, anon;
grant execute on function public.tg_discover() to authenticated;
grant execute on function public.tg_test() to authenticated;
grant execute on function public.tg_result(bigint) to authenticated;
revoke all on function public.tg_order_text(public.orders) from public, anon, authenticated;
