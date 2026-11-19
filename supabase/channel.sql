-- Channel page (/c): shows the products of the suppliers chosen in settings.chan.sups (even if hidden in the shop).
-- With no supplier chosen it shows the shop's visible products. Only product data is returned (no costs).
create or replace function public.channel_products(store text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare sups int[]; r jsonb;
begin
  select array(select (x #>> '{}')::int from jsonb_array_elements(coalesce(data->'chan'->'sups','[]'::jsonb)) x where (x #>> '{}') ~ '^[0-9]+$')
    into sups from public.settings where store_id = store;
  if sups is null or cardinality(sups) = 0 then
    select coalesce(jsonb_agg(p.data order by p.ref), '[]') into r from public.products p where p.store_id = store and coalesce(p.data->>'hidden','false') <> 'true';
  else
    select coalesce(jsonb_agg(p.data order by p.ref), '[]') into r from public.products p
      where p.store_id = store and coalesce(p.data->>'chanHide','false') <> 'true'
        and exists (select 1 from public.product_costs c where c.product_id = p.id and c.store_id = store and c.supplier_id = any(sups)
                    and (c.is_main or not exists (select 1 from public.product_costs c2 where c2.product_id = p.id and c2.store_id = store and c2.is_main)));
  end if;
  return r;
end $$;
revoke all on function public.channel_products(text) from public;
grant execute on function public.channel_products(text) to anon, authenticated;
