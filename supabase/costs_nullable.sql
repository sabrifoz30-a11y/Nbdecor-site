-- a product can be linked to a supplier before its purchase price is known
alter table public.product_costs alter column cost drop not null;
