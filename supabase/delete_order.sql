-- Owner deletes an order in any status. Supplier ledger lines keep their amounts (link cleared); purchases of the order are removed.
create or replace function public.delete_order(oid bigint) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if not exists (select 1 from public.orders where id = oid and store_id = public.my_store()) then raise exception 'no order'; end if;
  update public.supplier_ledger set order_id = null where order_id = oid;
  delete from public.capi_log where order_id = oid;
  delete from public.orders where id = oid and store_id = public.my_store();
end $$;
revoke all on function public.delete_order(bigint) from public, anon;
grant execute on function public.delete_order(bigint) to authenticated;
