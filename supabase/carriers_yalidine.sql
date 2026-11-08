-- Yalidine family (Yalidine, Guepex, Yalitec, Easy & Speed, Speedmail): API ID + API Token sent as X-API-ID / X-API-TOKEN headers.
-- Both are stored hidden: secrets 'carrier:<id>' (token) and 'carrier:<id>-apiid' (API ID).
create or replace function public.carrier_call(cid text, path text, q jsonb default '{}'::jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare tok text; aid text; base text; comp jsonb; rid bigint;
begin
  if public.my_role() not in ('owner','confirmer') then raise exception 'not allowed'; end if;
  select value into tok from public.secrets where key = 'carrier:'||cid;
  if tok is null then raise exception 'no token'; end if;
  select c into comp from public.settings s, jsonb_array_elements(coalesce(s.data->'shipping'->'companies','[]'::jsonb)) c where s.id = 1 and c->>'id' = cid;
  base := rtrim(coalesce(comp->>'base',''),'/');
  if base !~ '^https://[a-z0-9.-]+$' then raise exception 'bad base url'; end if;
  if comp->>'platform' = 'yalidine' then
    if path not in ('/v1/wilayas/','/v1/communes/','/v1/centers/','/v1/fees/','/v1/deliveryfees/','/v1/histories/') then raise exception 'path not allowed'; end if;
    select value into aid from public.secrets where key = 'carrier:'||cid||'-apiid';
    if aid is null then raise exception 'no api id'; end if;
    select net.http_get(url := base||path, params := q,
      headers := jsonb_build_object('X-API-ID', aid, 'X-API-TOKEN', tok, 'Accept','application/json'), timeout_milliseconds := 20000) into rid;
  else
    if path not in ('/api/v1/get/wilayas','/api/v1/get/fees','/api/v1/get/communes','/api/v1/get/tracking/info') then raise exception 'path not allowed'; end if;
    select net.http_get(url := base||path, params := q || jsonb_build_object('api_token', tok),
      headers := jsonb_build_object('Authorization','Bearer '||tok,'Accept','application/json'), timeout_milliseconds := 20000) into rid;
  end if;
  return rid;
end $$;
revoke all on function public.carrier_call(text,text,jsonb) from public, anon;
grant execute on function public.carrier_call(text,text,jsonb) to authenticated;
