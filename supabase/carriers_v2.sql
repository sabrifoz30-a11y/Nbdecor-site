-- carrier_result also returns the redirect target so the page can follow a moved platform
create or replace function public.carrier_result(rid bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if public.my_role() not in ('owner','confirmer') then raise exception 'not allowed'; end if;
  select status_code, content, error_msg, timed_out, headers into r from net._http_response where id = rid;
  if not found then return jsonb_build_object('done', false); end if;
  return jsonb_build_object('done', true, 'status', r.status_code, 'error', r.error_msg, 'timed_out', r.timed_out,
    'location', coalesce(r.headers->>'location', r.headers->>'Location'), 'body', left(coalesce(r.content,''), 200000));
end $$;
