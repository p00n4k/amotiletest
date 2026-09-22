-- ============================================================================
--  AMO — ระบบใบยืนยันการสั่งซื้อ (Order Confirmation System)
--  PostgreSQL 16 · schema.sql
--
--  4 schema:
--    auth     — ผู้ใช้ / บทบาท / สิทธิ์ / session
--    catalog  — แคตตาล็อกสินค้า (กระเบื้อง + เฟอร์นิเจอร์) — admin ดูแล
--    sales    — ลูกค้า + เอกสาร OC/Quotation/Proforma — sales สร้าง
--    audit    — ประวัติการแก้ไขทุกตาราง
--
--  หลักการออกแบบ:
--    1) เอกสารที่ออกไปแล้วต้อง "แช่แข็ง" — ทุกบรรทัดใน sales.document_items
--       เก็บสำเนาสเปก/ราคา ณ วันที่ขาย ไม่ผูกราคากับแคตตาล็อกแบบ live
--    2) เก็บทั้ง input (ลูกค้าแจ้งมาเท่าไร เผื่อกี่ %) และ output (ปัดกล่องแล้วกี่กล่อง
--       เป็นเงินเท่าไร) เพื่อให้คำนวณซ้ำและตรวจย้อนหลังได้
--    3) แก้ใบที่อนุมัติแล้ว = ออก revision ใหม่ ไม่ทับของเดิม
--    4) ทุกการเปลี่ยนแปลงลง audit.activity_log อัตโนมัติด้วย trigger
--
--  ⚠ ไฟล์นี้กับ db/catalog.sql เป็น "ทางเลือก" ไม่ใช่ของที่ใช้คู่กัน
--     ไฟล์นี้มีส่วนแคตตาล็อกอยู่ในตัวอยู่แล้ว — catalog.sql คือส่วนสินค้าที่ตัดออกมา
--     ใช้ตอนอยากแยกเป็นคนละฐานข้อมูล รันทั้งคู่ในฐานข้อมูลเดียวกันจะชนกัน
-- ============================================================================

-- ล้างของเดิมก่อนรันซ้ำ — เอาคอมเมนต์ออกเมื่อต้องการสร้างใหม่ทั้งหมด
-- domain อยู่ระดับฐานข้อมูล (ใช้ข้าม schema) จึงต้องลบแยกจาก schema
-- DROP SCHEMA IF EXISTS sales CASCADE;
-- DROP SCHEMA IF EXISTS catalog CASCADE;
-- DROP SCHEMA IF EXISTS audit CASCADE;
-- DROP SCHEMA IF EXISTS auth CASCADE;
-- DROP DOMAIN IF EXISTS money_thb, qty_num, pct_num CASCADE;

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;     -- อีเมลไม่สนตัวพิมพ์ใหญ่เล็ก
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- ค้นหาชื่อสินค้า/ลูกค้าแบบ fuzzy

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS catalog;
CREATE SCHEMA IF NOT EXISTS sales;
CREATE SCHEMA IF NOT EXISTS audit;

-- ---------------------------------------------------------------- domains ---
CREATE DOMAIN money_thb AS numeric(14,2);  -- จำนวนเงิน (บาท)
CREATE DOMAIN qty_num   AS numeric(14,4);  -- จำนวน/พื้นที่ — ทศนิยม 4 ตำแหน่ง
CREATE DOMAIN pct_num   AS numeric(6,3) CHECK (VALUE >= 0 AND VALUE <= 100);

-- ------------------------------------------------------------------ enums ---
CREATE TYPE catalog.product_type   AS ENUM ('tile','furniture');
CREATE TYPE catalog.item_status    AS ENUM ('active','discontinued');
-- U.M. = หน่วยราคาสินค้า (ตารางเมตร / เมตร / ชิ้น / เซ็ต / กล่อง)
CREATE TYPE catalog.price_unit     AS ENUM ('sqm','meter','piece','set','box');

CREATE TYPE sales.doc_type         AS ENUM ('order_confirmation','quotation','proforma_invoice');
CREATE TYPE sales.doc_status       AS ENUM ('draft','pending_approval','approved','sent','accepted','cancelled','superseded');
CREATE TYPE sales.row_kind         AS ENUM ('product','image','note');
CREATE TYPE sales.allowance_type   AS ENUM ('none','percent','piece','box');
CREATE TYPE sales.selling_method   AS ENUM ('box','piece','set');
CREATE TYPE sales.discount_type    AS ENUM ('none','percent','amount');
CREATE TYPE sales.order_type       AS ENUM ('stock','indent');
CREATE TYPE sales.approval_result  AS ENUM ('approved','rejected');

-- ============================================================================
--  AUTH — ผู้ใช้ / บทบาท / สิทธิ์
-- ============================================================================

CREATE TABLE auth.roles (
  id          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        text NOT NULL UNIQUE,          -- admin | manager | sales | viewer
  name_th     text NOT NULL,
  description text,
  is_system   boolean NOT NULL DEFAULT false -- บทบาทหลัก ลบไม่ได้
);

CREATE TABLE auth.permissions (
  code           text PRIMARY KEY,           -- 'document.create', 'catalog.price.update'
  group_name     text NOT NULL,              -- จัดกลุ่มตอนแสดงในหน้า admin
  description_th text NOT NULL
);

CREATE TABLE auth.role_permissions (
  role_id         smallint NOT NULL REFERENCES auth.roles(id) ON DELETE CASCADE,
  permission_code text     NOT NULL REFERENCES auth.permissions(code) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_code)
);

CREATE TABLE auth.users (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email                citext NOT NULL UNIQUE,
  password_hash        text NOT NULL,            -- argon2id — ไม่เคยออกจาก DB
  display_name         text NOT NULL,            -- "Panumard (Ann)"
  phone                text,
  signature_line       text,                     -- บรรทัดช่องเซ็นในใบ OC
  manager_id           uuid REFERENCES auth.users(id),
  is_active            boolean NOT NULL DEFAULT true,
  must_change_password boolean NOT NULL DEFAULT true,
  last_login_at        timestamptz,
  failed_login_count   int NOT NULL DEFAULT 0,
  locked_until         timestamptz,              -- ล็อกชั่วคราวหลังใส่รหัสผิดหลายครั้ง
  created_at           timestamptz NOT NULL DEFAULT now(),
  created_by           uuid REFERENCES auth.users(id),
  updated_at           timestamptz,
  updated_by           uuid REFERENCES auth.users(id),
  deleted_at           timestamptz,
  deleted_by           uuid REFERENCES auth.users(id)
);
CREATE INDEX users_active_idx ON auth.users (is_active) WHERE deleted_at IS NULL;

-- ผู้ใช้ 1 คนมีได้หลายบทบาท (เช่น sales ที่เป็น manager ของทีมด้วย)
CREATE TABLE auth.user_roles (
  user_id    uuid     NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role_id    smallint NOT NULL REFERENCES auth.roles(id) ON DELETE RESTRICT,
  granted_at timestamptz NOT NULL DEFAULT now(),
  granted_by uuid REFERENCES auth.users(id),
  PRIMARY KEY (user_id, role_id)
);

-- refresh token 1 แถว = 1 อุปกรณ์ที่ล็อกอินค้างไว้
-- (access token เป็น JWT อายุสั้น ไม่เก็บลง DB)
CREATE TABLE auth.sessions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  refresh_token_hash bytea NOT NULL UNIQUE,     -- เก็บแค่ sha256(token)
  user_agent         text,
  ip                 inet,
  issued_at          timestamptz NOT NULL DEFAULT now(),
  last_used_at       timestamptz,
  expires_at         timestamptz NOT NULL,
  revoked_at         timestamptz,
  revoked_reason     text
);
CREATE INDEX sessions_live_idx ON auth.sessions (user_id) WHERE revoked_at IS NULL;

CREATE TABLE auth.password_resets (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token_hash bytea NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- บันทึกการพยายามล็อกอิน ใช้ทำ rate-limit และตรวจการบุกรุก
CREATE TABLE auth.login_attempts (
  id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email   citext,
  ip      inet,
  success boolean NOT NULL,
  reason  text,                                 -- bad_password | locked | inactive
  at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX login_attempts_at_idx ON auth.login_attempts USING brin (at);

-- ผู้ใช้ปัจจุบัน — API ตั้งค่านี้ทุก transaction: SET LOCAL app.user_id = '<uuid>'
CREATE FUNCTION auth.current_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $fn$
  SELECT nullif(current_setting('app.user_id', true), '')::uuid;
$fn$;

CREATE FUNCTION auth.current_user_name() RETURNS text
LANGUAGE sql STABLE AS $fn$
  SELECT display_name FROM auth.users WHERE id = auth.current_user_id();
$fn$;

CREATE FUNCTION auth.has_permission(p_code text) RETURNS boolean
LANGUAGE sql STABLE AS $fn$
  SELECT EXISTS (
    SELECT 1
      FROM auth.user_roles ur
      JOIN auth.role_permissions rp ON rp.role_id = ur.role_id
     WHERE ur.user_id = auth.current_user_id()
       AND rp.permission_code = p_code
  );
$fn$;

-- ============================================================================
--  AUDIT — ประวัติการแก้ไขทุกตาราง
-- ============================================================================

CREATE TABLE audit.activity_log (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at    timestamptz NOT NULL DEFAULT now(),
  actor_id       uuid REFERENCES auth.users(id),
  actor_name     text,            -- คัดลอกชื่อไว้ เผื่อผู้ใช้ถูกลบภายหลัง
  action         text NOT NULL,   -- insert|update|delete|approve|revise|send|price_change|login
  schema_name    text NOT NULL,
  table_name     text NOT NULL,
  record_id      text NOT NULL,
  document_id    uuid,            -- ผูกกับใบ OC เพื่อดึง timeline ของใบเดียวได้เร็ว
  changed_fields text[],
  old_values     jsonb,
  new_values     jsonb,
  note           text,            -- เหตุผลที่ผู้ใช้พิมพ์เอง
  request_id     uuid,            -- ผูกทุกแถวที่เกิดจาก HTTP request เดียวกัน
  ip             inet
);
CREATE INDEX activity_occurred_idx ON audit.activity_log USING brin (occurred_at);
CREATE INDEX activity_record_idx   ON audit.activity_log (schema_name, table_name, record_id);
CREATE INDEX activity_doc_idx      ON audit.activity_log (document_id, occurred_at DESC) WHERE document_id IS NOT NULL;
CREATE INDEX activity_actor_idx    ON audit.activity_log (actor_id, occurred_at DESC);

-- ชื่อคอลัมน์ภาษาไทย — ให้หน้า "ประวัติการแก้ไข" แสดง "ราคาต่อหน่วย" แทน price_per_unit
CREATE TABLE audit.field_labels (
  table_name  text NOT NULL,
  column_name text NOT NULL,
  label_th    text NOT NULL,
  PRIMARY KEY (table_name, column_name)
);

-- คอลัมน์ที่ไม่บันทึกลงประวัติ (ข้อมูลลับ)
CREATE FUNCTION audit.redact(p jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT p - 'password_hash' - 'refresh_token_hash' - 'token_hash';
$fn$;

CREATE FUNCTION audit.log_changes() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
  v_old jsonb; v_new jsonb; v_rec jsonb; v_fields text[]; v_pk text[]; v_id text; v_doc uuid;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_new := audit.redact(to_jsonb(NEW));
  ELSIF TG_OP = 'UPDATE' THEN
    v_old := audit.redact(to_jsonb(OLD));
    v_new := audit.redact(to_jsonb(NEW));
    SELECT array_agg(n.key ORDER BY n.key) INTO v_fields
      FROM jsonb_each(v_new) AS n(key, value)
     WHERE n.value IS DISTINCT FROM v_old -> n.key
       AND n.key <> ALL (ARRAY['updated_at','updated_by']);
    IF v_fields IS NULL THEN RETURN NEW; END IF;   -- กดบันทึกแต่ค่าไม่เปลี่ยน ไม่ต้องลงประวัติ
  ELSE
    v_old := audit.redact(to_jsonb(OLD));
  END IF;

  -- อ่าน primary key จริงจาก catalog — ไม่สมมติว่าทุกตารางมีคอลัมน์ชื่อ id
  -- composite PK (auth.user_roles) จะได้ค่าต่อกันด้วย ':' ส่วนตาราง 1:1
  -- (catalog.tile_specs, sales.document_items) ใช้ product_id / row_id เป็น PK
  v_rec := COALESCE(v_new, v_old);

  SELECT array_agg(a.attname ORDER BY a.attnum) INTO v_pk
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
   WHERE i.indrelid = TG_RELID AND i.indisprimary;

  SELECT string_agg(v_rec ->> u.col, ':' ORDER BY u.ord) INTO v_id
    FROM unnest(v_pk) WITH ORDINALITY AS u(col, ord);

  v_id  := COALESCE(v_id, '?');
  v_doc := CASE
             WHEN TG_TABLE_NAME = 'documents' THEN v_id::uuid
             ELSE nullif(COALESCE(v_new ->> 'document_id', v_old ->> 'document_id'), '')::uuid
           END;

  INSERT INTO audit.activity_log (
    actor_id, actor_name, action, schema_name, table_name, record_id,
    document_id, changed_fields, old_values, new_values, note, request_id, ip
  ) VALUES (
    auth.current_user_id(), auth.current_user_name(), lower(TG_OP),
    TG_TABLE_SCHEMA, TG_TABLE_NAME, v_id,
    v_doc, v_fields, v_old, v_new,
    nullif(current_setting('app.note', true), ''),
    nullif(current_setting('app.request_id', true), '')::uuid,
    nullif(current_setting('app.ip', true), '')::inet
  );
  RETURN COALESCE(NEW, OLD);
END $fn$;

-- created_at/by, updated_at/by อัตโนมัติ — API ส่งมาเองไม่ได้
CREATE FUNCTION audit.touch_row() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.created_at := now();
    NEW.created_by := COALESCE(NEW.created_by, auth.current_user_id());
  ELSE
    NEW.created_at := OLD.created_at;
    NEW.created_by := OLD.created_by;
    NEW.updated_at := now();
    NEW.updated_by := auth.current_user_id();
  END IF;
  RETURN NEW;
END $fn$;

-- ติด trigger ทั้งสองตัวให้ตารางเดียวจบ: CALL audit.attach('catalog','products');
-- ตารางที่ไม่มีคอลัมน์ created_at/created_by ให้ส่ง p_touch => false
-- (เช่น auth.user_roles ที่ใช้ granted_at/granted_by และ sales.document_items
--  ที่ยืมคอลัมน์ชุดนี้จาก document_rows ซึ่งเป็นแถวแม่)
CREATE PROCEDURE audit.attach(p_schema text, p_table text, p_touch boolean DEFAULT true)
LANGUAGE plpgsql AS $fn$
BEGIN
  IF p_touch THEN
    EXECUTE format('CREATE TRIGGER %I_touch BEFORE INSERT OR UPDATE ON %I.%I
                    FOR EACH ROW EXECUTE FUNCTION audit.touch_row()', p_table, p_schema, p_table);
  END IF;
  EXECUTE format('CREATE TRIGGER %I_audit AFTER INSERT OR UPDATE OR DELETE ON %I.%I
                  FOR EACH ROW EXECUTE FUNCTION audit.log_changes()', p_table, p_schema, p_table);
END $fn$;

-- ============================================================================
--  CATALOG — แคตตาล็อกสินค้า (admin ดูแล · sales อ่านอย่างเดียว)
-- ============================================================================

CREATE TABLE catalog.brands (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text NOT NULL,
  status           catalog.item_status NOT NULL DEFAULT 'active',
  discontinued_at  timestamptz,
  discontinued_by  uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id),
  deleted_at timestamptz, deleted_by uuid REFERENCES auth.users(id)
);
CREATE UNIQUE INDEX brands_name_key ON catalog.brands (lower(name)) WHERE deleted_at IS NULL;

-- หมวดหมู่หลัก — Tile, Table, Sofa, Chair
CREATE TABLE catalog.categories (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL,
  product_type catalog.product_type,            -- จำกัดว่าหมวดนี้ใช้กับสินค้าประเภทไหน
  sort_order   int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id),
  deleted_at timestamptz, deleted_by uuid REFERENCES auth.users(id)
);
CREATE UNIQUE INDEX categories_name_key ON catalog.categories (lower(name)) WHERE deleted_at IS NULL;

-- หมวดหมู่ย่อย — Floor Tile, Wall Tile, Coffee Table, 3 Seater
-- ไม่มี product_type ของตัวเอง เพราะสืบทอดจากหมวดหลักเสมอ
CREATE TABLE catalog.subcategories (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id uuid NOT NULL REFERENCES catalog.categories(id),
  name        text NOT NULL,
  sort_order  int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id),
  deleted_at timestamptz, deleted_by uuid REFERENCES auth.users(id),
  -- ให้ products อ้างเป็นคู่ได้ เพื่อกันหมวดย่อยข้ามหมวดหลัก (ดูคอมเมนต์ที่ products)
  UNIQUE (id, category_id)
);
CREATE UNIQUE INDEX subcategories_name_key
  ON catalog.subcategories (category_id, lower(name)) WHERE deleted_at IS NULL;
CREATE INDEX subcategories_category_idx ON catalog.subcategories (category_id, sort_order);

CREATE TABLE catalog.collections (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  brand_id uuid NOT NULL REFERENCES catalog.brands(id),
  name     text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id),
  deleted_at timestamptz, deleted_by uuid REFERENCES auth.users(id)
);
CREATE UNIQUE INDEX collections_brand_name_key
  ON catalog.collections (brand_id, lower(name)) WHERE deleted_at IS NULL;

CREATE TABLE catalog.products (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sku             text NOT NULL,
  product_type    catalog.product_type NOT NULL,
  brand_id        uuid REFERENCES catalog.brands(id),
  collection_id   uuid REFERENCES catalog.collections(id),
  category_id     uuid REFERENCES catalog.categories(id),   -- หมวดหลัก
  subcategory_id  uuid,                 -- หมวดย่อย — FK เป็นคู่กับ category_id ดูข้างล่าง
  name            text,
  description     text,
  width_cm        numeric(10,2),        -- เฟอร์นิเจอร์: กว้าง × ยาว × สูง
  length_cm       numeric(10,2),
  height_cm       numeric(10,2),
  default_qty_unit text,                -- เฟอร์นิเจอร์: ชิ้น | ตัว | ชุด
  status          catalog.item_status NOT NULL DEFAULT 'active',
  discontinued_at timestamptz,
  discontinued_by uuid REFERENCES auth.users(id),
  search_tsv      tsvector GENERATED ALWAYS AS (
                    to_tsvector('simple', coalesce(sku,'') || ' ' || coalesce(name,''))
                  ) STORED,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id),
  deleted_at timestamptz, deleted_by uuid REFERENCES auth.users(id),
  -- อ้างหมวดย่อยเป็นคู่ (subcategory_id, category_id) — FK จะปฏิเสธถ้าหมวดย่อยที่เลือก
  -- ไม่ได้อยู่ใต้หมวดหลักที่เลือก เช่น หมวดหลัก Sofa + หมวดย่อย Floor Tile
  -- subcategory_id เป็น NULL ได้ (MATCH SIMPLE จะข้ามการตรวจให้เอง)
  FOREIGN KEY (subcategory_id, category_id)
    REFERENCES catalog.subcategories (id, category_id)
);
CREATE UNIQUE INDEX products_sku_key ON catalog.products (upper(sku)) WHERE deleted_at IS NULL;
CREATE INDEX products_subcategory_idx ON catalog.products (subcategory_id);
CREATE INDEX products_search_idx     ON catalog.products USING gin (search_tsv);
CREATE INDEX products_name_trgm_idx  ON catalog.products USING gin (name gin_trgm_ops);
CREATE INDEX products_browse_idx     ON catalog.products (product_type, status, brand_id);

-- รูปสินค้าหลัก และรูปประจำตัวเลือก อยู่ตารางเดียวกัน จะได้โชว์รวมในแกลเลอรีเดียว
CREATE TABLE catalog.product_images (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
  option_id  uuid,                           -- NULL = รูปหลักของสินค้า
  file_path  text NOT NULL,                  -- object key บน S3/MinIO
  caption    text,
  is_primary boolean NOT NULL DEFAULT false,
  sort_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id)
);
CREATE UNIQUE INDEX product_images_one_primary
  ON catalog.product_images (product_id) WHERE is_primary;

-- สเปกกระเบื้อง 1:1 กับ products — ตัวขับสูตรคำนวณทั้งหมด
CREATE TABLE catalog.tile_specs (
  product_id     uuid PRIMARY KEY REFERENCES catalog.products(id) ON DELETE CASCADE,
  item           text,                         -- Item / ลาย เช่น Stone, Marble
  color          text,
  surface        text,
  sale_w_cm      numeric(10,2), sale_l_cm numeric(10,2), sale_h_cm numeric(10,2),
  work_w_cm      numeric(10,2), work_l_cm numeric(10,2), work_h_cm numeric(10,2),
  price_unit     catalog.price_unit NOT NULL,  -- U.M.
  price_per_unit money_thb NOT NULL CHECK (price_per_unit > 0),
  sqm_per_box    qty_num NOT NULL CHECK (sqm_per_box > 0),
  pieces_per_box qty_num NOT NULL CHECK (pieces_per_box > 0),
  kg_per_box     qty_num CHECK (kg_per_box IS NULL OR kg_per_box >= 0),
  -- ขายเป็นเมตร ต้องมีความยาวแผ่น ไม่งั้นคำนวณเมตรไม่ได้
  CHECK (price_unit <> 'meter' OR (sale_l_cm IS NOT NULL AND sale_l_cm > 0)),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id)
);

-- 1 ตัวเลือก = 1 รูปแบบสินค้าที่มีราคาเดียว (เฟอร์นิเจอร์)
CREATE TABLE catalog.product_options (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
  label      text,                             -- ชื่อตัวเลือก (ไม่บังคับ)
  price      money_thb NOT NULL CHECK (price >= 0),
  sort_order int NOT NULL DEFAULT 0,
  status     catalog.item_status NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id),
  deleted_at timestamptz, deleted_by uuid REFERENCES auth.users(id)
);
CREATE INDEX product_options_product_idx ON catalog.product_options (product_id, sort_order);

ALTER TABLE catalog.product_images
  ADD CONSTRAINT product_images_option_fk
  FOREIGN KEY (option_id) REFERENCES catalog.product_options(id) ON DELETE CASCADE;

-- ชิ้นส่วนภายในตัวเลือก — Top / Base / Legs + วัสดุ (ไม่มีราคาแยก)
CREATE TABLE catalog.option_parts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  option_id       uuid NOT NULL REFERENCES catalog.product_options(id) ON DELETE CASCADE,
  title           text NOT NULL,               -- Top
  sub_description text,                        -- GreyWood ผิวเมลามีน
  sort_order      int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id)
);
CREATE UNIQUE INDEX option_parts_title_key ON catalog.option_parts (option_id, lower(title));

-- ประวัติราคา — เขียนโดย trigger ทุกครั้งที่ราคาเปลี่ยน
CREATE TABLE catalog.price_history (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id uuid REFERENCES catalog.products(id) ON DELETE CASCADE,        -- กระเบื้อง
  option_id  uuid REFERENCES catalog.product_options(id) ON DELETE CASCADE, -- เฟอร์นิเจอร์
  old_price  money_thb,
  new_price  money_thb NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by uuid REFERENCES auth.users(id),
  note       text,
  CHECK (num_nonnulls(product_id, option_id) = 1)
);
CREATE INDEX price_history_product_idx ON catalog.price_history (product_id, changed_at DESC);
CREATE INDEX price_history_option_idx  ON catalog.price_history (option_id,  changed_at DESC);

CREATE FUNCTION catalog.log_price_change() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE v_old money_thb; v_new money_thb;
BEGIN
  IF TG_TABLE_NAME = 'tile_specs' THEN
    v_old := OLD.price_per_unit; v_new := NEW.price_per_unit;
    IF v_new IS DISTINCT FROM v_old THEN
      INSERT INTO catalog.price_history (product_id, old_price, new_price, changed_by,
                                         note)
      VALUES (NEW.product_id, v_old, v_new, auth.current_user_id(),
              nullif(current_setting('app.note', true), ''));
    END IF;
  ELSE
    v_old := OLD.price; v_new := NEW.price;
    IF v_new IS DISTINCT FROM v_old THEN
      INSERT INTO catalog.price_history (option_id, old_price, new_price, changed_by, note)
      VALUES (NEW.id, v_old, v_new, auth.current_user_id(),
              nullif(current_setting('app.note', true), ''));
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

CREATE TRIGGER tile_price_hist  AFTER UPDATE ON catalog.tile_specs
  FOR EACH ROW EXECUTE FUNCTION catalog.log_price_change();
CREATE TRIGGER option_price_hist AFTER UPDATE ON catalog.product_options
  FOR EACH ROW EXECUTE FUNCTION catalog.log_price_change();

-- ============================================================================
--  SALES — ลูกค้า, ค่าตั้งต้นบริษัท, เอกสาร OC
-- ============================================================================

CREATE TABLE sales.customers (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code       text NOT NULL,                    -- 1A-TE-00160
  name       text NOT NULL,
  address    text,
  tax_id     text,
  branch     text DEFAULT 'สำนักงานใหญ่',
  owner_id   uuid REFERENCES auth.users(id),   -- sales เจ้าของลูกค้า
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id),
  deleted_at timestamptz, deleted_by uuid REFERENCES auth.users(id)
);
CREATE UNIQUE INDEX customers_code_key ON sales.customers (upper(code)) WHERE deleted_at IS NULL;
CREATE INDEX customers_name_trgm_idx   ON sales.customers USING gin (name gin_trgm_ops);

CREATE TABLE sales.customer_contacts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES sales.customers(id) ON DELETE CASCADE,
  name        text NOT NULL,                   -- Attn: K.ปรีชา
  position    text,
  phone       text,
  email       citext,
  is_primary  boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id)
);

-- ข้อมูลผู้ขาย + ค่าตั้งต้นท้ายเอกสาร — admin ตั้งครั้งเดียว ใช้ทุกใบ
CREATE TABLE sales.company_profiles (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  address       text,
  tel           text,
  mobile        text,
  email         citext,
  tax_id        text,
  bank_line     text,            -- "Amo Co.,Ltd, Krungthai Bank, xxx-x-xxxxx-x"
  logo_path     text,
  terms_default text,            -- Terms & Conditions ตั้งต้น
  vat_pct       pct_num NOT NULL DEFAULT 7,
  validity_default text DEFAULT '30 Days',
  sign_manager_title text,
  sign_manager_name  text,
  is_default    boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id)
);
CREATE UNIQUE INDEX company_one_default ON sales.company_profiles (is_default) WHERE is_default;

-- แคตตาล็อกค่าใช้จ่ายอื่น (ค่าตัดกระเบื้อง, pickup, ขนส่ง ตจว., พาเลท)
CREATE TABLE sales.fee_types (
  code       text PRIMARY KEY,        -- tile_cutting | pickup | upcountry | pallet
  label_th   text NOT NULL,
  label_en   text NOT NULL,
  is_taxable boolean NOT NULL DEFAULT true,
  sort_order int NOT NULL DEFAULT 0,
  is_active  boolean NOT NULL DEFAULT true
);

-- ---------------------------------------------------------------------------
--  เอกสาร — 1 แถว = 1 ใบ (1 option, 1 revision)
--  doc_no คงเดิมตลอดดีล, option_no = ทางเลือกที่เสนอลูกค้า, revision_no = การแก้ไข
-- ---------------------------------------------------------------------------
CREATE TABLE sales.documents (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_type          sales.doc_type NOT NULL DEFAULT 'order_confirmation',
  doc_no            text NOT NULL,                    -- A26-11736
  option_no         int  NOT NULL DEFAULT 0,
  revision_no       int  NOT NULL DEFAULT 1,
  status            sales.doc_status NOT NULL DEFAULT 'draft',
  is_current        boolean NOT NULL DEFAULT true,    -- revision ล่าสุดของ option นี้
  supersedes_id     uuid REFERENCES sales.documents(id),  -- revision ก่อนหน้า
  cloned_from_id    uuid REFERENCES sales.documents(id),  -- ก๊อปมาจากใบ/option ไหน

  -- คู่ค้า: อ้าง id ไว้ทำรายงาน + เก็บสำเนาไว้พิมพ์ (ลูกค้าย้ายที่อยู่ ใบเก่าต้องไม่เปลี่ยน)
  customer_id       uuid REFERENCES sales.customers(id),
  customer_code     text,
  customer_name     text NOT NULL,
  customer_address  text,
  attn              text,

  company_profile_id uuid REFERENCES sales.company_profiles(id),
  company_snapshot   jsonb NOT NULL DEFAULT '{}',     -- ชื่อ/ที่อยู่/tel/tax id ณ วันออกใบ

  project_ref       text,                             -- "1A-บริษัท เทอร์ริคอน จำกัด -18/2/2026"
  issue_date        date NOT NULL DEFAULT current_date,
  validity_text     text,
  owner_id          uuid NOT NULL REFERENCES auth.users(id),   -- sales เจ้าของใบ
  prepared_by_name  text,                             -- From (ผู้จัดทำ)

  bill_discount_type  sales.discount_type NOT NULL DEFAULT 'none',
  bill_discount_value numeric(14,4) NOT NULL DEFAULT 0,
  vat_pct             pct_num NOT NULL DEFAULT 7,
  currency            char(3) NOT NULL DEFAULT 'THB',
  terms               text,
  sign_sales_line     text,
  sign_company        text,
  sign_manager_title  text,
  sign_manager_name   text,

  -- ยอดที่ freeze ไว้ (คำนวณโดย sales.recalc_document)
  amount_gross        money_thb NOT NULL DEFAULT 0,   -- ก่อนลดรายชิ้น
  amount_item_discount money_thb NOT NULL DEFAULT 0,
  amount_line_total   money_thb NOT NULL DEFAULT 0,   -- = ผลรวมคอลัมน์ AMOUNT
  amount_bill_discount money_thb NOT NULL DEFAULT 0,
  amount_subtotal     money_thb NOT NULL DEFAULT 0,
  amount_fees         money_thb NOT NULL DEFAULT 0,
  amount_tax_base     money_thb NOT NULL DEFAULT 0,
  amount_vat          money_thb NOT NULL DEFAULT 0,
  amount_grand        money_thb NOT NULL DEFAULT 0,

  locked_at         timestamptz,                      -- ตั้งตอน approve — แก้ต่อไม่ได้
  locked_by         uuid REFERENCES auth.users(id),
  sent_at           timestamptz,
  row_version       int NOT NULL DEFAULT 1,           -- optimistic locking (If-Match)

  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id),
  deleted_at timestamptz, deleted_by uuid REFERENCES auth.users(id),

  UNIQUE (doc_no, option_no, revision_no)
);
-- แต่ละ option มี revision ที่ "ใช้อยู่" ได้ใบเดียว
CREATE UNIQUE INDEX documents_current_key
  ON sales.documents (doc_no, option_no) WHERE is_current AND deleted_at IS NULL;
CREATE INDEX documents_owner_idx    ON sales.documents (owner_id, status, issue_date DESC);
CREATE INDEX documents_customer_idx ON sales.documents (customer_id, issue_date DESC);

-- ลำดับแถวในเอกสาร — สินค้า/รูปที่แทรก/โน้ต เรียงรวมกันในลิสต์เดียว
CREATE TABLE sales.document_rows (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id uuid NOT NULL REFERENCES sales.documents(id) ON DELETE CASCADE,
  sort_order  int NOT NULL,
  kind        sales.row_kind NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid REFERENCES auth.users(id),
  updated_at timestamptz, updated_by uuid REFERENCES auth.users(id)
);
-- ต้องเป็น constraint ไม่ใช่ index เพราะ DEFERRABLE ใช้กับ index เปล่า ๆ ไม่ได้
-- เลื่อนการตรวจไปตอน COMMIT เพื่อให้สลับลำดับทั้งชุดได้ใน transaction เดียว
ALTER TABLE sales.document_rows
  ADD CONSTRAINT document_rows_order_key UNIQUE (document_id, sort_order)
  DEFERRABLE INITIALLY DEFERRED;

-- รูป/โน้ตที่ sales แทรกคั่นระหว่างรายการ
CREATE TABLE sales.document_media (
  row_id    uuid PRIMARY KEY REFERENCES sales.document_rows(id) ON DELETE CASCADE,
  file_path text,
  caption   text,
  note_text text
);

-- ---------------------------------------------------------------------------
--  บรรทัดสินค้า — สำเนาแคตตาล็อก + input ที่ sales กรอก + ผลคำนวณที่แช่แข็งไว้
-- ---------------------------------------------------------------------------
CREATE TABLE sales.document_items (
  row_id          uuid PRIMARY KEY REFERENCES sales.document_rows(id) ON DELETE CASCADE,
  document_id     uuid NOT NULL REFERENCES sales.documents(id) ON DELETE CASCADE,

  -- อ้างอิงต้นทาง (ทำรายงานยอดขายรายสินค้า) — ห้ามใช้ join เอาราคามาพิมพ์
  product_id      uuid REFERENCES catalog.products(id),
  option_id       uuid REFERENCES catalog.product_options(id),

  -- ===== สำเนาแคตตาล็อก ณ วันที่ขาย =====
  product_type    catalog.product_type NOT NULL,
  sku             text NOT NULL,
  product_name    text,
  brand_name      text,
  collection_name text,
  category_name   text,
  subcategory_name text,
  variant_label   text,                       -- Item (กระเบื้อง)
  image_path      text,
  dim_w_cm numeric(10,2), dim_l_cm numeric(10,2), dim_h_cm numeric(10,2),
  work_w_cm numeric(10,2), work_l_cm numeric(10,2), work_h_cm numeric(10,2),
  price_unit      catalog.price_unit,         -- U.M. ตอนขาย
  catalog_price   money_thb NOT NULL,         -- ราคาต่อหน่วยจากแคตตาล็อก ณ วันนั้น
  sqm_per_box     qty_num,
  pieces_per_box  qty_num,
  kg_per_box      qty_num,
  option_parts    jsonb NOT NULL DEFAULT '[]', -- [{"title":"Top","sub":"GreyWood"}]

  -- ===== input ที่ sales กรอก =====
  customer_unit    catalog.price_unit,        -- ลูกค้าแจ้งจำนวนเป็นหน่วยใด
  customer_qty     qty_num,
  allowance_type   sales.allowance_type NOT NULL DEFAULT 'none',
  allowance_value  numeric(14,4) NOT NULL DEFAULT 0,
  selling_method   sales.selling_method,      -- ปัดกล่อง / ชิ้น / เซ็ต
  qty_unit_label   text,                      -- เฟอร์นิเจอร์: ชิ้น | ตัว | ชุด
  order_type       sales.order_type NOT NULL DEFAULT 'stock',
  remark           text,
  discount_type    sales.discount_type NOT NULL DEFAULT 'none',
  discount_value   numeric(14,4) NOT NULL DEFAULT 0,

  -- ===== ผลคำนวณ (server คำนวณ · แช่แข็งไว้กับใบ) =====
  required_pieces  qty_num,                   -- ก่อนปัด (จำนวนใช้จริง + เผื่อ)
  actual_pieces    qty_num,
  actual_boxes     qty_num,
  actual_sqm       qty_num,
  actual_meters    qty_num,
  total_weight_kg  qty_num,
  billed_qty       qty_num NOT NULL,          -- จำนวนที่พิมพ์ในเอกสาร (หน่วยลูกค้า)
  billed_unit      text NOT NULL,             -- sqm | m | pcs | sets | boxes | ชุด
  unit_price_doc   money_thb NOT NULL,        -- ถอดกลับจากยอดรวม: billed_qty × นี่ = gross
  amount_gross     money_thb NOT NULL,
  amount_discount  money_thb NOT NULL DEFAULT 0,
  amount_net       money_thb NOT NULL,
  desc_lines       text[] NOT NULL DEFAULT '{}',  -- บรรทัดใน DESCRIPTION ที่พิมพ์จริง

  CHECK (amount_discount <= amount_gross),
  CHECK (amount_net = amount_gross - amount_discount),
  CHECK (product_type <> 'tile' OR (pieces_per_box > 0 AND sqm_per_box > 0))
);
CREATE INDEX document_items_doc_idx     ON sales.document_items (document_id);
CREATE INDEX document_items_product_idx ON sales.document_items (product_id);

-- ค่าใช้จ่ายอื่นท้ายบิล
CREATE TABLE sales.document_fees (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id uuid NOT NULL REFERENCES sales.documents(id) ON DELETE CASCADE,
  fee_code    text REFERENCES sales.fee_types(code),
  label_th    text NOT NULL,
  label_en    text NOT NULL,
  amount      money_thb NOT NULL CHECK (amount >= 0),
  is_taxable  boolean NOT NULL DEFAULT true,
  sort_order  int NOT NULL DEFAULT 0
);

-- งวดการชำระเงิน — งวดสุดท้าย percent = NULL หมายถึง "ส่วนที่เหลือ"
CREATE TABLE sales.document_payment_terms (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id uuid NOT NULL REFERENCES sales.documents(id) ON DELETE CASCADE,
  seq         int NOT NULL,
  percent     pct_num,
  amount      money_thb,
  note        text NOT NULL,                  -- "upon order confirmation"
  UNIQUE (document_id, seq)
);

-- ---------------------------------------------------------------------------
--  ประวัติ: snapshot ทั้งใบ + การเปลี่ยนสถานะ + การอนุมัติ
-- ---------------------------------------------------------------------------
CREATE TABLE sales.document_revisions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id uuid NOT NULL REFERENCES sales.documents(id) ON DELETE CASCADE,
  revision_no int NOT NULL,
  snapshot    jsonb NOT NULL,                 -- ทั้งใบ: head + rows + fees + totals
  reason      text NOT NULL,                  -- บังคับกรอกตอนขอแก้ไข
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid REFERENCES auth.users(id),
  UNIQUE (document_id, revision_no)
);

CREATE TABLE sales.document_status_history (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  document_id uuid NOT NULL REFERENCES sales.documents(id) ON DELETE CASCADE,
  from_status sales.doc_status,
  to_status   sales.doc_status NOT NULL,
  note        text,
  changed_at  timestamptz NOT NULL DEFAULT now(),
  changed_by  uuid REFERENCES auth.users(id)
);
CREATE INDEX doc_status_hist_idx ON sales.document_status_history (document_id, changed_at DESC);

CREATE TABLE sales.document_approvals (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id  uuid NOT NULL REFERENCES sales.documents(id) ON DELETE CASCADE,
  requested_by uuid NOT NULL REFERENCES auth.users(id),
  requested_at timestamptz NOT NULL DEFAULT now(),
  decided_by   uuid REFERENCES auth.users(id),
  decided_at   timestamptz,
  result       sales.approval_result,
  comment      text
);

-- ============================================================================
--  กติกาแก้ไขเอกสาร + สูตรคำนวณ
-- ============================================================================

-- ใบที่ล็อกแล้วห้ามแก้ ยกเว้นมีสิทธิ์ document.edit.locked (admin)
CREATE FUNCTION sales.guard_locked() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE v_locked timestamptz;
BEGIN
  SELECT locked_at INTO v_locked FROM sales.documents
   WHERE id = COALESCE(NEW.document_id, OLD.document_id);

  IF v_locked IS NOT NULL AND NOT auth.has_permission('document.edit.locked') THEN
    RAISE EXCEPTION 'เอกสารถูกล็อกแล้ว (อนุมัติเมื่อ %) — ต้องออก revision ใหม่', v_locked
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $fn$;

CREATE TRIGGER items_guard  BEFORE INSERT OR UPDATE OR DELETE ON sales.document_items
  FOR EACH ROW EXECUTE FUNCTION sales.guard_locked();
CREATE TRIGGER fees_guard   BEFORE INSERT OR UPDATE OR DELETE ON sales.document_fees
  FOR EACH ROW EXECUTE FUNCTION sales.guard_locked();

-- รวมยอดทั้งใบใหม่ — เรียกหลังแก้บรรทัด/ค่าธรรมเนียม/ส่วนลดท้ายบิล
CREATE FUNCTION sales.recalc_document(p_doc uuid) RETURNS sales.documents
LANGUAGE plpgsql AS $fn$
DECLARE d sales.documents; v_gross money_thb; v_disc money_thb; v_fees money_thb; v_bill money_thb;
BEGIN
  SELECT * INTO d FROM sales.documents WHERE id = p_doc FOR UPDATE;

  SELECT COALESCE(sum(amount_gross),0), COALESCE(sum(amount_discount),0)
    INTO v_gross, v_disc
    FROM sales.document_items WHERE document_id = p_doc;

  SELECT COALESCE(sum(amount),0) INTO v_fees
    FROM sales.document_fees WHERE document_id = p_doc;

  v_bill := CASE d.bill_discount_type
              WHEN 'percent' THEN (v_gross - v_disc) * d.bill_discount_value / 100
              WHEN 'amount'  THEN d.bill_discount_value
              ELSE 0 END;
  v_bill := least(greatest(v_bill, 0), v_gross - v_disc);   -- ลดเกินยอดไม่ได้

  UPDATE sales.documents SET
    amount_gross         = v_gross,
    amount_item_discount = v_disc,
    amount_line_total    = v_gross - v_disc,
    amount_bill_discount = v_bill,
    amount_subtotal      = v_gross - v_disc - v_bill,
    amount_fees          = v_fees,
    amount_tax_base      = v_gross - v_disc - v_bill + v_fees,
    amount_vat           = round((v_gross - v_disc - v_bill + v_fees) * vat_pct / 100, 2),
    amount_grand         = round((v_gross - v_disc - v_bill + v_fees) * (100 + vat_pct) / 100, 2),
    row_version          = row_version + 1
  WHERE id = p_doc
  RETURNING * INTO d;

  -- เกลี่ยยอดแต่ละงวดตาม Grand Total (งวดที่ percent เป็น NULL = ส่วนที่เหลือ)
  UPDATE sales.document_payment_terms t
     SET amount = round(d.amount_grand * t.percent / 100, 2)
   WHERE t.document_id = p_doc AND t.percent IS NOT NULL;

  UPDATE sales.document_payment_terms t
     SET amount = d.amount_grand - COALESCE(
           (SELECT sum(amount) FROM sales.document_payment_terms
             WHERE document_id = p_doc AND percent IS NOT NULL), 0)
   WHERE t.document_id = p_doc AND t.percent IS NULL;

  RETURN d;
END $fn$;

CREATE FUNCTION sales.snapshot_document(p_doc uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$
  SELECT jsonb_build_object(
    'document', to_jsonb(d),
    'rows', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                      'row', to_jsonb(r), 'item', to_jsonb(i), 'media', to_jsonb(m))
                      ORDER BY r.sort_order), '[]'::jsonb)
               FROM sales.document_rows r
               LEFT JOIN sales.document_items i ON i.row_id = r.id
               LEFT JOIN sales.document_media m ON m.row_id = r.id
              WHERE r.document_id = d.id),
    'fees', (SELECT COALESCE(jsonb_agg(to_jsonb(f) ORDER BY f.sort_order), '[]'::jsonb)
               FROM sales.document_fees f WHERE f.document_id = d.id),
    'payment_terms', (SELECT COALESCE(jsonb_agg(to_jsonb(p) ORDER BY p.seq), '[]'::jsonb)
               FROM sales.document_payment_terms p WHERE p.document_id = d.id)
  )
  FROM sales.documents d WHERE d.id = p_doc;
$fn$;

-- ปิดใบเดิมก่อนออก revision ใหม่ — จุดเดียวที่บังคับ "ต้องมีเหตุผล" และเป็นที่เดียว
-- ที่แตะ is_current/superseded  (การโคลน head+rows+items+fees ทำใน service layer
-- เพราะเขียนเป็น SQL แล้วต้องไล่ชื่อคอลัมน์ทีละตัว แก้ schema ทีก็ลืมแก้ที)
CREATE FUNCTION sales.close_for_revision(p_doc uuid, p_reason text) RETURNS int
LANGUAGE plpgsql AS $fn$
DECLARE v_rev int;
BEGIN
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'ต้องระบุเหตุผลในการแก้ไข' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO sales.document_revisions (document_id, revision_no, snapshot, reason, created_by)
  SELECT id, revision_no, sales.snapshot_document(id), p_reason, auth.current_user_id()
    FROM sales.documents WHERE id = p_doc
  RETURNING revision_no + 1 INTO v_rev;

  UPDATE sales.documents
     SET is_current = false,
         status     = 'superseded'
   WHERE id = p_doc;

  INSERT INTO sales.document_status_history (document_id, from_status, to_status, note, changed_by)
  VALUES (p_doc, NULL, 'superseded', p_reason, auth.current_user_id());

  RETURN v_rev;   -- เลข revision ที่ service ต้องใช้ตอนสร้างใบใหม่
END $fn$;

-- ============================================================================
--  ROW LEVEL SECURITY — sales เห็นเฉพาะใบของตัวเอง, manager เห็นของทีม
-- ============================================================================
ALTER TABLE sales.documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY documents_read ON sales.documents FOR SELECT USING (
  auth.has_permission('document.read.all')
  OR owner_id = auth.current_user_id()
  OR owner_id IN (SELECT id FROM auth.users WHERE manager_id = auth.current_user_id())
);

CREATE POLICY documents_write ON sales.documents FOR UPDATE USING (
  auth.has_permission('document.update.all')
  OR (owner_id = auth.current_user_id() AND status = 'draft')
);

CREATE POLICY documents_insert ON sales.documents FOR INSERT WITH CHECK (
  auth.has_permission('document.create')
);

-- ============================================================================
--  ติด trigger บันทึกประวัติ
-- ============================================================================
DO $do$
DECLARE t record;
BEGIN
  FOR t IN
    SELECT * FROM (VALUES
      ('catalog','brands',            true),
      ('catalog','categories',        true),
      ('catalog','subcategories',     true),
      ('catalog','collections',       true),
      ('catalog','products',          true),
      ('catalog','product_images',    true),
      ('catalog','tile_specs',        true),
      ('catalog','product_options',   true),
      ('catalog','option_parts',      true),
      ('sales','customers',           true),
      ('sales','customer_contacts',   true),
      ('sales','company_profiles',    true),
      ('sales','documents',           true),
      ('sales','document_rows',       true),
      ('sales','document_items',      false),  -- ไม่มีคอลัมน์ created_at/by ของตัวเอง
      ('auth','users',                true),
      ('auth','user_roles',           false)   -- ใช้ granted_at/granted_by แทน
    ) AS v(s, n, touch)
  LOOP
    CALL audit.attach(t.s, t.n, t.touch);
  END LOOP;
END $do$;

-- ============================================================================
--  ข้อมูลตั้งต้น
-- ============================================================================
INSERT INTO auth.roles (code, name_th, description, is_system) VALUES
  ('admin',   'ผู้ดูแลระบบ', 'ดูแลแคตตาล็อก ผู้ใช้ และแก้ไขใบที่อนุมัติแล้วได้', true),
  ('manager', 'หัวหน้าฝ่ายขาย', 'อนุมัติเอกสาร และดูใบของทีมทั้งหมด', true),
  ('sales',   'พนักงานขาย', 'สร้างและแก้ไขใบของตัวเองตอนเป็นฉบับร่าง', true),
  ('viewer',  'ผู้ดูข้อมูล', 'ดูอย่างเดียว เช่น บัญชี/คลังสินค้า', true);

INSERT INTO auth.permissions (code, group_name, description_th) VALUES
  ('catalog.read',           'แคตตาล็อก', 'ดูสินค้าและราคา'),
  ('catalog.create',         'แคตตาล็อก', 'เพิ่มสินค้า/แบรนด์/คอลเลกชัน'),
  ('catalog.update',         'แคตตาล็อก', 'แก้ไขข้อมูลสินค้า'),
  ('catalog.price.update',   'แคตตาล็อก', 'แก้ไขราคาและตัวเลือกสินค้า'),
  ('catalog.discontinue',    'แคตตาล็อก', 'ทำเครื่องหมายไม่ขายแล้ว'),
  ('customer.read',          'ลูกค้า',    'ดูข้อมูลลูกค้า'),
  ('customer.manage',        'ลูกค้า',    'เพิ่ม/แก้ไขลูกค้า'),
  ('document.create',        'เอกสาร',    'สร้างใบ OC/ใบเสนอราคา'),
  ('document.update.own',    'เอกสาร',    'แก้ไขใบของตัวเอง (ฉบับร่าง)'),
  ('document.update.all',    'เอกสาร',    'แก้ไขใบของทุกคน'),
  ('document.edit.locked',   'เอกสาร',    'แก้ไขใบที่อนุมัติ/ล็อกแล้ว'),
  ('document.read.all',      'เอกสาร',    'ดูใบของทุกคน'),
  ('document.approve',       'เอกสาร',    'อนุมัติ / ไม่อนุมัติเอกสาร'),
  ('document.revise',        'เอกสาร',    'ออก revision ใหม่'),
  ('document.send',          'เอกสาร',    'ส่งเอกสารให้ลูกค้า'),
  ('document.cancel',        'เอกสาร',    'ยกเลิกเอกสาร'),
  ('settings.manage',        'ตั้งค่า',    'แก้ข้อมูลบริษัท เงื่อนไข ค่าธรรมเนียม'),
  ('user.manage',            'ผู้ใช้',     'จัดการผู้ใช้และบทบาท'),
  ('audit.read',             'ประวัติ',    'ดูประวัติการแก้ไขทั้งระบบ');

INSERT INTO auth.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM auth.roles r, auth.permissions p WHERE r.code = 'admin';

INSERT INTO auth.role_permissions (role_id, permission_code)
SELECT r.id, c FROM auth.roles r, unnest(ARRAY[
  'catalog.read','customer.read','customer.manage','document.create','document.update.own',
  'document.update.all','document.read.all','document.approve','document.revise',
  'document.send','document.cancel','audit.read'
]) AS c WHERE r.code = 'manager';

INSERT INTO auth.role_permissions (role_id, permission_code)
SELECT r.id, c FROM auth.roles r, unnest(ARRAY[
  'catalog.read','customer.read','customer.manage',
  'document.create','document.update.own','document.send'
]) AS c WHERE r.code = 'sales';

INSERT INTO auth.role_permissions (role_id, permission_code)
SELECT r.id, c FROM auth.roles r, unnest(ARRAY['catalog.read','customer.read'])
  AS c WHERE r.code = 'viewer';

INSERT INTO sales.fee_types (code, label_th, label_en, sort_order) VALUES
  ('tile_cutting', 'ค่าตัดกระเบื้อง',                      'Tile Cutting',       1),
  ('pickup',       'ค่า Pickup',                          'Pickup Charge',      2),
  ('upcountry',    'ค่าขนส่งต่างจังหวัด',                   'Upcountry Delivery', 3),
  ('pallet',       'ค่าพาเลท (ซื้อแผ่นใหญ่ไม่เต็มพาเลท)',    'Pallet Charge',      4);

INSERT INTO audit.field_labels (table_name, column_name, label_th) VALUES
  ('tile_specs','price_per_unit','ราคาต่อหน่วย'),
  ('tile_specs','sqm_per_box','ตร.ม./กล่อง'),
  ('tile_specs','pieces_per_box','ชิ้น/กล่อง'),
  ('product_options','price','ราคาตัวเลือก'),
  ('document_items','customer_qty','จำนวนที่ลูกค้าต้องการ'),
  ('document_items','allowance_value','จำนวนเผื่อ'),
  ('document_items','discount_value','ส่วนลดรายชิ้น'),
  ('documents','vat_pct','อัตราภาษี (%)'),
  ('documents','bill_discount_value','ส่วนลดท้ายบิล'),
  ('documents','terms','เงื่อนไขท้ายเอกสาร');
