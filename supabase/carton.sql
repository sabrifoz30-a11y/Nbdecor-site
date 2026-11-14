-- optional purchase price of a full carton at this supplier
alter table public.product_costs add column if not exists carton_cost int check (carton_cost is null or carton_cost >= 0);
