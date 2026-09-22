-- ============================================================================
--  AMO — แคตตาล็อกสินค้า (กระเบื้อง + เฟอร์นิเจอร์) เป็นฐานข้อมูลเดี่ยว
--  PostgreSQL 16 · catalog.sql
--
--  ตัดออกมาจาก db/schema.sql เฉพาะส่วนสินค้า รันได้เองไม่ต้องพึ่ง schema อื่น
--
--  10 ตาราง:
--    ใช้ร่วมกันทั้งสองประเภท   brands · categories · subcategories · collections
--                             products · product_images
--    เฉพาะกระเบื้อง            tile_specs           (1:1 กับ products)
--    เฉพาะเฟอร์นิเจอร์          product_options      (1:N)
--                             option_parts         (ชิ้นส่วนในตัวเลือก)
--    ประวัติ                   price_history
--
--  แกนของโครงคือ products — คอลัมน์ product_type เป็นตัวตัดสินว่าสินค้าตัวนี้
--  ต่อกับ tile_specs หรือ product_options ข้อมูลที่ใช้ร่วมกัน (SKU แบรนด์
--  คอลเลกชัน หมวดหมู่ รูป) อยู่ที่ products ที่เดียว ไม่ต้องทำสองชุด
--
--  หมายเหตุเรื่องผู้ใช้: ไฟล์นี้ไม่มีตาราง users เพราะแยกฐานข้อมูลกับระบบ auth
--  คอลัมน์ created_by / updated_by / deleted_by / discontinued_by / changed_by
--  เก็บ uuid ของผู้ใช้เฉย ๆ ไม่มี FK — ตอนแสดงผลให้ service ไปถามชื่อจาก auth
--  ถ้ารวมฐานข้อมูลเดียวกับ schema.sql ให้เติม REFERENCES auth.users(id) กลับเข้าไป
--
--  ⚠ ไฟล์นี้กับ db/schema.sql เป็น "ทางเลือก" ไม่ใช่ของที่ใช้คู่กัน
--     ห้ามรันทั้งสองไฟล์ในฐานข้อมูลเดียวกัน เพราะสร้าง schema catalog, enum
--     และตารางชุดเดียวกัน — schema.sql มีส่วนสินค้าอยู่ในตัวอยู่แล้ว
-- ============================================================================

-- ล้างของเดิมก่อนรันซ้ำ — เอาคอมเมนต์ออกเมื่อต้องการสร้างใหม่ทั้งหมด
-- (ทุกอย่างอยู่ใน schema catalog รวมทั้ง domain บรรทัดเดียวจึงล้างหมด)
-- DROP SCHEMA IF EXISTS catalog CASCADE;

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- ค้นหาชื่อสินค้าแบบพิมพ์ผิดได้

CREATE SCHEMA IF NOT EXISTS catalog;

-- ---------------------------------------------------------------- domains ---
CREATE DOMAIN catalog.money_thb AS numeric(14,2);  -- จำนวนเงิน (บาท)
CREATE DOMAIN catalog.qty_num   AS numeric(14,4);  -- จำนวน/พื้นที่ — ทศนิยม 4 ตำแหน่ง

-- ------------------------------------------------------------------ enums ---
CREATE TYPE catalog.product_type AS ENUM ('tile','furniture');
CREATE TYPE catalog.item_status  AS ENUM ('active','discontinued');
-- U.M. = หน่วยราคาสินค้า (ตารางเมตร / เมตร / ชิ้น / เซ็ต / กล่อง)
CREATE TYPE catalog.price_unit   AS ENUM ('sqm','meter','piece','set','box');

-- ผู้ใช้ปัจจุบัน — API ตั้งค่านี้ทุก transaction: SET LOCAL app.user_id = '<uuid>'
CREATE FUNCTION catalog.current_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $fn$
  SELECT nullif(current_setting('app.user_id', true), '')::uuid;
$fn$;

-- created_at/by, updated_at/by อัตโนมัติ — API ส่งมาเองไม่ได้
CREATE FUNCTION catalog.touch_row() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.created_at := now();
    NEW.created_by := COALESCE(NEW.created_by, catalog.current_user_id());
  ELSE
    NEW.created_at := OLD.created_at;
    NEW.created_by := OLD.created_by;
    NEW.updated_at := now();
    NEW.updated_by := catalog.current_user_id();
  END IF;
  RETURN NEW;
END $fn$;

-- ============================================================================
--  ใช้ร่วมกันทั้งกระเบื้องและเฟอร์นิเจอร์
-- ============================================================================

CREATE TABLE catalog.brands (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text NOT NULL,                     -- Cotto, Natuzzi, Botempi
  status           catalog.item_status NOT NULL DEFAULT 'active',
  discontinued_at  timestamptz,
  discontinued_by  uuid,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz, updated_by uuid,
  deleted_at timestamptz, deleted_by uuid            -- soft delete
);
CREATE UNIQUE INDEX brands_name_key ON catalog.brands (lower(name)) WHERE deleted_at IS NULL;

-- หมวดหมู่หลัก — Tile, Table, Sofa, Chair
CREATE TABLE catalog.categories (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL,
  product_type catalog.product_type,                  -- เว้นว่าง = ใช้ได้ทั้งสองประเภท
  sort_order   int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz, updated_by uuid,
  deleted_at timestamptz, deleted_by uuid
);
CREATE UNIQUE INDEX categories_name_key ON catalog.categories (lower(name)) WHERE deleted_at IS NULL;

-- หมวดหมู่ย่อย — Floor Tile, Wall Tile, Coffee Table, 3 Seater
-- ไม่มี product_type ของตัวเอง เพราะสืบทอดจากหมวดหลักเสมอ
CREATE TABLE catalog.subcategories (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id uuid NOT NULL REFERENCES catalog.categories(id),
  name        text NOT NULL,
  sort_order  int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz, updated_by uuid,
  deleted_at timestamptz, deleted_by uuid,
  -- ให้ products อ้างเป็นคู่ได้ เพื่อกันหมวดย่อยข้ามหมวดหลัก (ดูคอมเมนต์ที่ products)
  UNIQUE (id, category_id)
);
CREATE UNIQUE INDEX subcategories_name_key
  ON catalog.subcategories (category_id, lower(name)) WHERE deleted_at IS NULL;
CREATE INDEX subcategories_category_idx ON catalog.subcategories (category_id, sort_order);

CREATE TABLE catalog.collections (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  brand_id uuid NOT NULL REFERENCES catalog.brands(id),  -- คอลเลกชันอยู่ใต้แบรนด์เสมอ
  name     text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz, updated_by uuid,
  deleted_at timestamptz, deleted_by uuid
);
CREATE UNIQUE INDEX collections_brand_name_key
  ON catalog.collections (brand_id, lower(name)) WHERE deleted_at IS NULL;

-- แกนกลาง — ข้อมูลที่กระเบื้องและเฟอร์นิเจอร์ใช้เหมือนกัน
CREATE TABLE catalog.products (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sku              text NOT NULL,                        -- TILE-6060-GRY, FUR-SOF-003
  product_type     catalog.product_type NOT NULL,        -- ตัวตัดสินว่าใช้ตารางขยายตัวไหน
  brand_id         uuid REFERENCES catalog.brands(id),
  collection_id    uuid REFERENCES catalog.collections(id),
  category_id      uuid REFERENCES catalog.categories(id),
  subcategory_id   uuid,                 -- FK เป็นคู่กับ category_id ดูข้างล่าง
  name             text,
  description      text,
  width_cm         numeric(10,2),        -- เฟอร์นิเจอร์: กว้าง × ยาว × สูง
  length_cm        numeric(10,2),        -- (กระเบื้องใช้ขนาดใน tile_specs แทน)
  height_cm        numeric(10,2),
  default_qty_unit text,                 -- เฟอร์นิเจอร์: ชิ้น | ตัว | ชุด
  status           catalog.item_status NOT NULL DEFAULT 'active',
  discontinued_at  timestamptz,
  discontinued_by  uuid,
  search_tsv       tsvector GENERATED ALWAYS AS (
                     to_tsvector('simple', coalesce(sku,'') || ' ' || coalesce(name,''))
                   ) STORED,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz, updated_by uuid,
  deleted_at timestamptz, deleted_by uuid,
  -- อ้างหมวดย่อยเป็นคู่ (subcategory_id, category_id) — FK จะปฏิเสธถ้าหมวดย่อยที่เลือก
  -- ไม่ได้อยู่ใต้หมวดหลักที่เลือก เช่น หมวดหลัก Sofa + หมวดย่อย Floor Tile
  -- subcategory_id เป็น NULL ได้ (MATCH SIMPLE จะข้ามการตรวจให้เอง)
  FOREIGN KEY (subcategory_id, category_id)
    REFERENCES catalog.subcategories (id, category_id)
);
CREATE UNIQUE INDEX products_sku_key ON catalog.products (upper(sku)) WHERE deleted_at IS NULL;
CREATE INDEX products_subcategory_idx ON catalog.products (subcategory_id);
CREATE INDEX products_search_idx    ON catalog.products USING gin (search_tsv);
CREATE INDEX products_name_trgm_idx ON catalog.products USING gin (name gin_trgm_ops);
CREATE INDEX products_browse_idx    ON catalog.products (product_type, status, brand_id);

-- รูปสินค้าหลักและรูปประจำตัวเลือก อยู่ตารางเดียวกัน จะได้โชว์รวมในแกลเลอรีเดียว
CREATE TABLE catalog.product_images (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
  option_id  uuid,                        -- NULL = รูปหลัก · FK เพิ่มหลัง product_options
  file_path  text NOT NULL,               -- object key บน S3/MinIO
  caption    text,
  is_primary boolean NOT NULL DEFAULT false,
  sort_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz, updated_by uuid
);
CREATE UNIQUE INDEX product_images_one_primary
  ON catalog.product_images (product_id) WHERE is_primary;
CREATE INDEX product_images_order_idx ON catalog.product_images (product_id, sort_order);

-- ============================================================================
--  เฉพาะกระเบื้อง — 1:1 กับ products · ตัวขับสูตรคำนวณทั้งหมดในใบ OC
-- ============================================================================

CREATE TABLE catalog.tile_specs (
  product_id     uuid PRIMARY KEY REFERENCES catalog.products(id) ON DELETE CASCADE,
  item           text,                         -- Item / ลาย เช่น Stone, Marble
  color          text,
  surface        text,                         -- เงา / ด้าน / R10 / R11 กันลื่น
  -- ขนาดขาย (Sale Size) = ที่พิมพ์บนกล่อง · ขนาดจริง (Working Size) = ตอนปูจริง
  sale_w_cm      numeric(10,2), sale_l_cm numeric(10,2), sale_h_cm numeric(10,2),
  work_w_cm      numeric(10,2), work_l_cm numeric(10,2), work_h_cm numeric(10,2),
  price_unit     catalog.price_unit NOT NULL,  -- U.M.
  price_per_unit catalog.money_thb NOT NULL CHECK (price_per_unit > 0),
  sqm_per_box    catalog.qty_num NOT NULL CHECK (sqm_per_box > 0),    -- ตัวหารของสูตรทั้งหมด
  pieces_per_box catalog.qty_num NOT NULL CHECK (pieces_per_box > 0), -- ใช้ปัดกล่อง
  kg_per_box     catalog.qty_num CHECK (kg_per_box IS NULL OR kg_per_box >= 0),
  -- ขายเป็นเมตร ต้องมีความยาวแผ่น ไม่งั้นคำนวณเมตรไม่ได้
  CHECK (price_unit <> 'meter' OR (sale_l_cm IS NOT NULL AND sale_l_cm > 0)),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz, updated_by uuid
);

-- ตร.ม. ต่อแผ่น — ตัวเลขที่สูตรในใบ OC ใช้บ่อยที่สุด
CREATE VIEW catalog.tile_sqm_per_piece AS
  SELECT product_id, sqm_per_box / pieces_per_box AS sqm_per_piece
    FROM catalog.tile_specs;

-- ============================================================================
--  เฉพาะเฟอร์นิเจอร์ — 1 ตัวเลือก = 1 รูปแบบสินค้าที่มีราคาเดียว
-- ============================================================================

CREATE TABLE catalog.product_options (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
  label      text,                              -- ชื่อตัวเลือก (ไม่บังคับ)
  price      catalog.money_thb NOT NULL CHECK (price >= 0),  -- ราคาทั้งชุด ไม่ใช่ต่อชิ้นส่วน
  sort_order int NOT NULL DEFAULT 0,            -- ลำดับที่โชว์ = ตัวเลือกที่ 1, 2, 3
  status     catalog.item_status NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz, updated_by uuid,
  deleted_at timestamptz, deleted_by uuid
);
CREATE INDEX product_options_product_idx ON catalog.product_options (product_id, sort_order);

ALTER TABLE catalog.product_images
  ADD CONSTRAINT product_images_option_fk
  FOREIGN KEY (option_id) REFERENCES catalog.product_options(id) ON DELETE CASCADE;

-- ชิ้นส่วนภายในตัวเลือก — Top / Base / Legs + วัสดุ (ไม่มีราคาแยก)
CREATE TABLE catalog.option_parts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  option_id       uuid NOT NULL REFERENCES catalog.product_options(id) ON DELETE CASCADE,
  title           text NOT NULL,               -- Top / Base / Legs / Upholstery
  sub_description text,                        -- GreyWood ผิวเมลามีน
  sort_order      int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz, updated_by uuid
);
CREATE UNIQUE INDEX option_parts_title_key ON catalog.option_parts (option_id, lower(title));

-- ============================================================================
--  ประวัติราคา — เขียนโดย trigger ทุกครั้งที่ราคาเปลี่ยน
-- ============================================================================

CREATE TABLE catalog.price_history (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id uuid REFERENCES catalog.products(id) ON DELETE CASCADE,        -- กระเบื้อง
  option_id  uuid REFERENCES catalog.product_options(id) ON DELETE CASCADE, -- เฟอร์นิเจอร์
  old_price  catalog.money_thb,                         -- NULL = ตั้งราคาครั้งแรก
  new_price  catalog.money_thb NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by uuid,
  note       text,
  CHECK (num_nonnulls(product_id, option_id) = 1)
);
CREATE INDEX price_history_product_idx ON catalog.price_history (product_id, changed_at DESC);
CREATE INDEX price_history_option_idx  ON catalog.price_history (option_id,  changed_at DESC);

CREATE FUNCTION catalog.log_price_change() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE v_old catalog.money_thb; v_new catalog.money_thb;
BEGIN
  IF TG_TABLE_NAME = 'tile_specs' THEN
    v_old := OLD.price_per_unit; v_new := NEW.price_per_unit;
    IF v_new IS DISTINCT FROM v_old THEN
      INSERT INTO catalog.price_history (product_id, old_price, new_price, changed_by, note)
      VALUES (NEW.product_id, v_old, v_new, catalog.current_user_id(),
              nullif(current_setting('app.note', true), ''));
    END IF;
  ELSE
    v_old := OLD.price; v_new := NEW.price;
    IF v_new IS DISTINCT FROM v_old THEN
      INSERT INTO catalog.price_history (option_id, old_price, new_price, changed_by, note)
      VALUES (NEW.id, v_old, v_new, catalog.current_user_id(),
              nullif(current_setting('app.note', true), ''));
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

CREATE TRIGGER tile_price_hist   AFTER UPDATE ON catalog.tile_specs
  FOR EACH ROW EXECUTE FUNCTION catalog.log_price_change();
CREATE TRIGGER option_price_hist AFTER UPDATE ON catalog.product_options
  FOR EACH ROW EXECUTE FUNCTION catalog.log_price_change();

-- ============================================================================
--  ติด trigger created_at/by, updated_at/by ให้ทุกตาราง
-- ============================================================================
DO $do$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'brands','categories','subcategories','collections','products','product_images',
    'tile_specs','product_options','option_parts'
  ] LOOP
    EXECUTE format('CREATE TRIGGER %I_touch BEFORE INSERT OR UPDATE ON catalog.%I
                    FOR EACH ROW EXECUTE FUNCTION catalog.touch_row()', t, t);
  END LOOP;
END $do$;

-- ============================================================================
--  มุมมองสำหรับช่องค้นหาสินค้าของ sales — รวมชื่อแบรนด์/คอลเลกชัน/หมวดหมู่ไว้แล้ว
-- ============================================================================
CREATE VIEW catalog.product_search AS
SELECT p.id,
       p.sku,
       p.product_type,
       p.name,
       b.name   AS brand_name,
       c.name   AS collection_name,
       cat.name AS category_name,
       sub.name AS subcategory_name,
       p.status,
       -- ราคาที่โชว์ในลิสต์: กระเบื้องใช้ราคาต่อหน่วย, เฟอร์นิเจอร์ใช้ราคาต่ำสุดของตัวเลือก
       COALESCE(ts.price_per_unit,
                (SELECT min(o.price) FROM catalog.product_options o
                  WHERE o.product_id = p.id AND o.deleted_at IS NULL
                    AND o.status = 'active')) AS display_price,
       ts.price_unit,
       (SELECT i.file_path FROM catalog.product_images i
         WHERE i.product_id = p.id AND i.is_primary LIMIT 1) AS primary_image
  FROM catalog.products p
  LEFT JOIN catalog.brands        b   ON b.id = p.brand_id
  LEFT JOIN catalog.collections   c   ON c.id = p.collection_id
  LEFT JOIN catalog.categories    cat ON cat.id = p.category_id
  LEFT JOIN catalog.subcategories sub ON sub.id = p.subcategory_id
  LEFT JOIN catalog.tile_specs    ts  ON ts.product_id = p.id
 WHERE p.deleted_at IS NULL;
