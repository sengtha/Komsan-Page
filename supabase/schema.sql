-- Komsan Page — silo content schema (starter template).
--
-- Run this on YOUR OWN Supabase project (the silo). Komsan visitors arrive with
-- a token whose `sub` is their Komsan user id and `app_metadata.silo_role` is
-- 'owner' (you) or 'visitor'. RLS below keys on both, with no shadow users.
--
-- Content model (no complicated levels):
--   status            : 'draft' | 'public'   (visitors see 'public' only)
--   publish_to_komsan : bool (default true)   (projected to the Komsan Hub feed
--                                              when public — see sync-to-hub)
--
-- Table shapes match what the Komsan client reads:
--   posts -> PageFeed | videos -> PageVideo | audio_tracks -> PageMusic

-- Owner check: the minted token carries app_metadata.silo_role.
-- (auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner'

CREATE TABLE IF NOT EXISTS public.posts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content text,
  media_url text,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'public')),
  publish_to_komsan boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Video (streaming): hls_url = an HLS manifest (your Cloudflare Stream / packager)
-- or a progressive file. thumbnail_url is the public preview shown in the feed.
CREATE TABLE IF NOT EXISTS public.videos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text,
  hls_url text,
  thumbnail_url text,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'public')),
  publish_to_komsan boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.audio_tracks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text,
  audio_url text,
  cover_art text,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'public')),
  publish_to_komsan boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Products (e-commerce). Prices in your chosen currency; images on your own R2.
CREATE TABLE IF NOT EXISTS public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text,
  price numeric(12, 2) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  image_url text,
  stock integer,                         -- null = unlimited
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'public')),
  publish_to_komsan boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Live streams. ws_url = base wss URL of your Normsar-DO worker; the client
-- opens `${ws_url}/chat/${room_id}?token=<silo token>`.
CREATE TABLE IF NOT EXISTS public.live_streams (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text,
  room_id text NOT NULL,
  ws_url text NOT NULL,
  status text NOT NULL DEFAULT 'offline' CHECK (status IN ('offline', 'live')),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Visitor comments — written as the visiting Komsan user (auth.uid()).
CREATE TABLE IF NOT EXISTS public.comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  author_uid uuid NOT NULL,
  target_type text NOT NULL CHECK (target_type IN ('post', 'video', 'audio')),
  target_id uuid NOT NULL,
  body text NOT NULL CHECK (char_length(body) <= 2000),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- RLS: visitors read PUBLIC content only; the owner reads/writes everything
-- (Page Studio). Comments: anyone reads, a visitor writes/deletes only their own.
-- ---------------------------------------------------------------------------
ALTER TABLE public.posts        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.videos       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audio_tracks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.live_streams ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comments     ENABLE ROW LEVEL SECURITY;

-- Public read of published content.
CREATE POLICY "read public posts"    ON public.posts        FOR SELECT USING (status = 'public');
CREATE POLICY "read public videos"   ON public.videos       FOR SELECT USING (status = 'public');
CREATE POLICY "read public tracks"   ON public.audio_tracks FOR SELECT USING (status = 'public');
CREATE POLICY "read public products" ON public.products     FOR SELECT USING (status = 'public');
CREATE POLICY "read live"            ON public.live_streams FOR SELECT USING (true);

-- Owner (Page Studio) full access.
CREATE POLICY "owner posts"  ON public.posts        FOR ALL
  USING ((auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner')
  WITH CHECK ((auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner');
CREATE POLICY "owner videos" ON public.videos       FOR ALL
  USING ((auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner')
  WITH CHECK ((auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner');
CREATE POLICY "owner tracks" ON public.audio_tracks FOR ALL
  USING ((auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner')
  WITH CHECK ((auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner');
CREATE POLICY "owner live"   ON public.live_streams FOR ALL
  USING ((auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner')
  WITH CHECK ((auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner');
CREATE POLICY "owner products" ON public.products FOR ALL
  USING ((auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner')
  WITH CHECK ((auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner');

-- Comments.
CREATE POLICY "read comments" ON public.comments FOR SELECT USING (true);
CREATE POLICY "visitor writes own comment" ON public.comments
  FOR INSERT WITH CHECK (author_uid = auth.uid());
CREATE POLICY "visitor deletes own comment" ON public.comments
  FOR DELETE USING (author_uid = auth.uid());

-- ---------------------------------------------------------------------------
-- Orders (e-commerce D2). A visiting Komsan user places an order; the price,
-- customer id and product snapshot are set server-side (anti-tamper). No
-- payment/delivery yet — the seller works the order from Page Studio.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_uid uuid NOT NULL,               -- Komsan user id (token sub)
  product_id uuid REFERENCES public.products(id) ON DELETE SET NULL,
  product_name text,                        -- snapshot (survives product deletion)
  qty integer NOT NULL DEFAULT 1 CHECK (qty > 0),
  unit_price numeric(12, 2) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  note text,
  contact text,
  status text NOT NULL DEFAULT 'placed' CHECK (status IN ('placed', 'confirmed', 'fulfilled', 'cancelled')),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;

-- Set customer + price server-side; validate availability. D3 will apply
-- discounts to unit_price here.
CREATE OR REPLACE FUNCTION public.set_order_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE p record;
BEGIN
  NEW.customer_uid := auth.uid();
  SELECT name, price, currency, status, stock INTO p FROM public.products WHERE id = NEW.product_id;
  IF p.name IS NULL OR p.status <> 'public' THEN
    RAISE EXCEPTION 'Product not available';
  END IF;
  IF p.stock IS NOT NULL AND p.stock < NEW.qty THEN
    RAISE EXCEPTION 'Not enough stock';
  END IF;
  NEW.product_name := p.name;
  NEW.unit_price   := p.price;
  NEW.currency     := p.currency;
  NEW.status       := 'placed';
  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS trg_set_order_defaults ON public.orders;
CREATE TRIGGER trg_set_order_defaults BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.set_order_defaults();

-- Customers place & see their own orders; the owner manages all of them.
CREATE POLICY "place order" ON public.orders
  FOR INSERT WITH CHECK (customer_uid = auth.uid());
CREATE POLICY "view own orders" ON public.orders
  FOR SELECT USING (customer_uid = auth.uid() OR (auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner');
CREATE POLICY "owner updates orders" ON public.orders
  FOR UPDATE USING ((auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner');

-- ---------------------------------------------------------------------------
-- Discounts (e-commerce D3). One flexible rule = window + trigger + reward +
-- scope. FULL STACKING: every applicable rule compounds; the price is floored
-- at 0. Prices are authoritative on the silo (set_order_defaults below); the
-- client mirrors this only for display. Daily windows use Cambodia local time.
--   scope     : product_id set = that product; null = store-wide
--   trigger   : min_qty (line quantity) | min_total (order subtotal) | neither
--   reward    : value_type percent|fixed + value
--   window    : starts_at/ends_at (absolute) and/or daily_start/daily_end
--   live_only : applies only while pinned in a live stream (wired in D4)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.discounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text,
  product_id uuid REFERENCES public.products(id) ON DELETE CASCADE,  -- null = store-wide
  value_type text NOT NULL CHECK (value_type IN ('percent', 'fixed')),
  value numeric(12, 2) NOT NULL CHECK (value >= 0),
  min_qty integer,
  min_total numeric(12, 2),
  live_only boolean NOT NULL DEFAULT false,
  starts_at timestamptz,
  ends_at timestamptz,
  daily_start time,
  daily_end time,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.discounts ENABLE ROW LEVEL SECURITY;
-- Active discounts are publicly readable (clients show the deal); owner manages.
CREATE POLICY "read active discounts" ON public.discounts FOR SELECT USING (active = true);
CREATE POLICY "owner discounts" ON public.discounts FOR ALL
  USING ((auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner')
  WITH CHECK ((auth.jwt() -> 'app_metadata' ->> 'silo_role') = 'owner');

-- Keep the pre-discount unit price on the order for a "was / now" display.
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS list_price numeric(12, 2);

-- set_order_defaults v2 — apply stacked discounts server-side (authoritative).
CREATE OR REPLACE FUNCTION public.set_order_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  p record;
  d record;
  v_unit numeric;
  v_subtotal numeric;
  v_now_t time := (now() AT TIME ZONE 'Asia/Phnom_Penh')::time;
BEGIN
  NEW.customer_uid := auth.uid();
  SELECT name, price, currency, status, stock INTO p FROM public.products WHERE id = NEW.product_id;
  IF p.name IS NULL OR p.status <> 'public' THEN
    RAISE EXCEPTION 'Product not available';
  END IF;
  IF p.stock IS NOT NULL AND p.stock < NEW.qty THEN
    RAISE EXCEPTION 'Not enough stock';
  END IF;

  NEW.product_name := p.name;
  NEW.currency     := p.currency;
  NEW.list_price   := p.price;
  v_unit := p.price;

  -- Line-level discounts (min_total IS NULL) — full stacking, floored at 0.
  FOR d IN SELECT * FROM public.discounts
    WHERE active AND min_total IS NULL AND live_only = false
      AND (product_id = NEW.product_id OR product_id IS NULL)
      AND (min_qty IS NULL OR NEW.qty >= min_qty)
      AND (starts_at IS NULL OR now() >= starts_at)
      AND (ends_at   IS NULL OR now() <= ends_at)
      AND (daily_start IS NULL OR daily_end IS NULL OR (v_now_t >= daily_start AND v_now_t <= daily_end))
  LOOP
    IF d.value_type = 'percent' THEN v_unit := v_unit * (1 - d.value / 100);
    ELSE v_unit := v_unit - d.value; END IF;
    IF v_unit < 0 THEN v_unit := 0; END IF;
  END LOOP;

  v_subtotal := v_unit * NEW.qty;

  -- Order-level discounts (min_total threshold on the subtotal).
  FOR d IN SELECT * FROM public.discounts
    WHERE active AND min_total IS NOT NULL AND live_only = false
      AND (product_id = NEW.product_id OR product_id IS NULL)
      AND v_subtotal >= min_total
      AND (starts_at IS NULL OR now() >= starts_at)
      AND (ends_at   IS NULL OR now() <= ends_at)
      AND (daily_start IS NULL OR daily_end IS NULL OR (v_now_t >= daily_start AND v_now_t <= daily_end))
  LOOP
    IF d.value_type = 'percent' THEN v_subtotal := v_subtotal * (1 - d.value / 100);
    ELSE v_subtotal := v_subtotal - d.value; END IF;
    IF v_subtotal < 0 THEN v_subtotal := 0; END IF;
  END LOOP;

  NEW.unit_price := round(v_subtotal / NEW.qty, 2);
  NEW.status := 'placed';
  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Live shopping (e-commerce D4). Pin one product to the live stream; live_only
-- discounts then activate for it. Order straight from the Live tab.
-- ---------------------------------------------------------------------------
ALTER TABLE public.live_streams ADD COLUMN IF NOT EXISTS pinned_product_id uuid REFERENCES public.products(id) ON DELETE SET NULL;

-- set_order_defaults v3 — include live_only discounts when the product is
-- currently pinned in an active live stream.
CREATE OR REPLACE FUNCTION public.set_order_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  p record;
  d record;
  v_unit numeric;
  v_subtotal numeric;
  v_live boolean;
  v_now_t time := (now() AT TIME ZONE 'Asia/Phnom_Penh')::time;
BEGIN
  NEW.customer_uid := auth.uid();
  SELECT name, price, currency, status, stock INTO p FROM public.products WHERE id = NEW.product_id;
  IF p.name IS NULL OR p.status <> 'public' THEN
    RAISE EXCEPTION 'Product not available';
  END IF;
  IF p.stock IS NOT NULL AND p.stock < NEW.qty THEN
    RAISE EXCEPTION 'Not enough stock';
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.live_streams WHERE status = 'live' AND pinned_product_id = NEW.product_id) INTO v_live;

  NEW.product_name := p.name;
  NEW.currency     := p.currency;
  NEW.list_price   := p.price;
  v_unit := p.price;

  FOR d IN SELECT * FROM public.discounts
    WHERE active AND min_total IS NULL AND (live_only = false OR v_live)
      AND (product_id = NEW.product_id OR product_id IS NULL)
      AND (min_qty IS NULL OR NEW.qty >= min_qty)
      AND (starts_at IS NULL OR now() >= starts_at)
      AND (ends_at   IS NULL OR now() <= ends_at)
      AND (daily_start IS NULL OR daily_end IS NULL OR (v_now_t >= daily_start AND v_now_t <= daily_end))
  LOOP
    IF d.value_type = 'percent' THEN v_unit := v_unit * (1 - d.value / 100);
    ELSE v_unit := v_unit - d.value; END IF;
    IF v_unit < 0 THEN v_unit := 0; END IF;
  END LOOP;

  v_subtotal := v_unit * NEW.qty;

  FOR d IN SELECT * FROM public.discounts
    WHERE active AND min_total IS NOT NULL AND (live_only = false OR v_live)
      AND (product_id = NEW.product_id OR product_id IS NULL)
      AND v_subtotal >= min_total
      AND (starts_at IS NULL OR now() >= starts_at)
      AND (ends_at   IS NULL OR now() <= ends_at)
      AND (daily_start IS NULL OR daily_end IS NULL OR (v_now_t >= daily_start AND v_now_t <= daily_end))
  LOOP
    IF d.value_type = 'percent' THEN v_subtotal := v_subtotal * (1 - d.value / 100);
    ELSE v_subtotal := v_subtotal - d.value; END IF;
    IF v_subtotal < 0 THEN v_subtotal := 0; END IF;
  END LOOP;

  NEW.unit_price := round(v_subtotal / NEW.qty, 2);
  NEW.status := 'placed';
  RETURN NEW;
END;
$function$;
