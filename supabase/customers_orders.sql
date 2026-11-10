create or replace function public.customer_orders(ph text) returns setof public.orders language plpgsql stable security definer set search_path = public as $$
begin
  if public.my_role() not in ('owner','confirmer') then raise exception 'not allowed'; end if;
  return query select * from public.orders where public.norm_phone(customer->>'phone') = public.norm_phone(ph) order by id desc limit 300;
end $$;
revoke all on function public.customer_orders(text) from public, anon;
grant execute on function public.customer_orders(text) to authenticated;
