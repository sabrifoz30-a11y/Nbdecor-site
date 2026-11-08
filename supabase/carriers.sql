-- delivery carriers (Ecotrack): hidden API tokens, server-side calls through pg_net
create or replace function public.set_secret(k text, v text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if not (k in ('fb_capi_token','tt_events_token') or k ~ '^carrier:[a-z0-9_-]{1,40}$') then raise exception 'unknown key'; end if;
  if v is null or length(trim(v)) = 0 then delete from public.secrets where key = k;
  else insert into public.secrets(key, value, updated_at) values (k, trim(v), now()) on conflict (key) do update set value = excluded.value, updated_at = now(); end if;
end $$;

create or replace function public.carrier_call(cid text, path text, q jsonb default '{}'::jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare tok text; base text; comp jsonb; rid bigint;
begin
  if public.my_role() not in ('owner','confirmer') then raise exception 'not allowed'; end if;
  if path not in ('/api/v1/get/wilayas','/api/v1/get/fees','/api/v1/get/communes','/api/v1/get/tracking/info') then raise exception 'path not allowed'; end if;
  select value into tok from public.secrets where key = 'carrier:'||cid;
  if tok is null then raise exception 'no token'; end if;
  select c into comp from public.settings s, jsonb_array_elements(coalesce(s.data->'shipping'->'companies','[]'::jsonb)) c where s.id = 1 and c->>'id' = cid;
  base := rtrim(coalesce(comp->>'base',''),'/');
  if base !~ '^https://[a-z0-9.-]+$' then raise exception 'bad base url'; end if;
  select net.http_get(url := base||path, params := q || jsonb_build_object('api_token', tok),
    headers := jsonb_build_object('Authorization','Bearer '||tok,'Accept','application/json'), timeout_milliseconds := 20000) into rid;
  return rid;
end $$;

create or replace function public.carrier_result(rid bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if public.my_role() not in ('owner','confirmer') then raise exception 'not allowed'; end if;
  select status_code, content, error_msg, timed_out into r from net._http_response where id = rid;
  if not found then return jsonb_build_object('done', false); end if;
  return jsonb_build_object('done', true, 'status', r.status_code, 'error', r.error_msg, 'timed_out', r.timed_out, 'body', left(coalesce(r.content,''), 200000));
end $$;
revoke all on function public.carrier_call(text,text,jsonb) from public, anon;
revoke all on function public.carrier_result(bigint) from public, anon;
grant execute on function public.carrier_call(text,text,jsonb) to authenticated;
grant execute on function public.carrier_result(bigint) to authenticated;
