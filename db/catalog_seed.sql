-- ============================================================================
--  AMO — ข้อมูลตัวอย่างสำหรับแคตตาล็อกสินค้า
--  PostgreSQL 16 · catalog_seed.sql   (รันหลัง db/catalog.sql)
--
--  ข้อมูลชุดนี้ยกมาจากสินค้าตัวอย่างใน all.html ทั้งหมด (tileSamples + furnSamples)
--  แล้วเติมเคสที่ mockup ไม่มีแต่ระบบจริงต้องรองรับ:
--    · แบรนด์และสินค้าที่ "ไม่ขายแล้ว" — ต้องหายจากช่องค้นหาแต่ใบเก่ายังอ้างได้
--    · สินค้าที่มีหลายรูป และรูปประจำตัวเลือก
--    · ประวัติราคาทั้งแบบย้ายมาจากระบบเก่า และแบบที่ trigger เขียนให้เอง
--
--    8 แบรนด์ · 4 หมวดหลัก · 7 หมวดย่อย · 8 คอลเลกชัน · 9 สินค้า (6 กระเบื้อง + 3 เฟอร์นิเจอร์)
--    6 tile_specs · 7 ตัวเลือก · 18 ชิ้นส่วน · 15 รูป · 5 ประวัติราคา
--
--  ⚠ ไฟล์นี้ TRUNCATE ตารางแคตตาล็อกทั้งหมดก่อน เพื่อให้รันซ้ำได้เรื่อย ๆ
--     ห้ามรันบนฐานข้อมูลจริงที่มีข้อมูลอยู่แล้ว
--
--  ใช้ชื่อ (แบรนด์ / SKU / ลำดับตัวเลือก) เป็นตัวเชื่อมแทน uuid ดิบ
--  จะได้อ่านออกและแก้ข้อมูลได้โดยไม่ต้องไล่ id
-- ============================================================================

BEGIN;

-- สมมติว่าเป็น admin คนนี้ที่นั่งกรอกข้อมูล — trigger touch_row จะหยิบไปใส่ created_by
SET LOCAL app.user_id = '3f1c8a6e-2b7d-4c91-9a55-0c2f7e8d1b40';

TRUNCATE catalog.price_history,
         catalog.option_parts,
         catalog.product_options,
         catalog.tile_specs,
         catalog.product_images,
         catalog.products,
         catalog.collections,
         catalog.subcategories,
         catalog.categories,
         catalog.brands
  RESTART IDENTITY CASCADE;

-- ============================================================================
--  แบรนด์
-- ============================================================================
INSERT INTO catalog.brands (name, status, discontinued_at) VALUES
  ('Cotto',    'active',       NULL),
  ('Duragres', 'active',       NULL),
  ('Sosuco',   'active',       NULL),
  ('Campana',  'active',       NULL),
  ('Botempi',  'active',       NULL),
  ('Natuzzi',  'active',       NULL),
  ('Hay',      'active',       NULL),
  -- เลิกเป็นตัวแทนจำหน่ายแล้ว — ยังลบไม่ได้เพราะใบเก่าอ้างชื่อนี้อยู่
  ('Lampas',   'discontinued', now() - interval '4 months');

-- ============================================================================
--  หมวดหมู่หลัก
-- ============================================================================
INSERT INTO catalog.categories (name, product_type, sort_order) VALUES
  ('Tile',  'tile',      1),
  ('Table', 'furniture', 2),
  ('Sofa',  'furniture', 3),
  ('Chair', 'furniture', 4);

-- ============================================================================
--  หมวดหมู่ย่อย — ไม่มี product_type ของตัวเอง สืบทอดจากหมวดหลัก
-- ============================================================================
INSERT INTO catalog.subcategories (category_id, name, sort_order)
SELECT c.id, v.name, v.ord
  FROM (VALUES
        ('Tile',  'Floor Tile',   1),
        ('Tile',  'Wall Tile',    2),
        ('Tile',  'Trim',         3),
        ('Tile',  'Decor',        4),
        ('Table', 'Coffee Table', 1),
        ('Sofa',  '3 Seater',     1),
        ('Chair', 'Dining Chair', 1)
       ) AS v(category, name, ord)
  JOIN catalog.categories c ON c.name = v.category;

-- ============================================================================
--  คอลเลกชัน — อยู่ใต้แบรนด์เสมอ
-- ============================================================================
INSERT INTO catalog.collections (brand_id, name)
SELECT b.id, v.name
  FROM (VALUES
        ('Cotto',    'Stone'),
        ('Cotto',    'Luxe'),
        ('Duragres', 'Pure'),
        ('Sosuco',   'Line'),
        ('Campana',  'Art'),
        ('Botempi',  'Core'),
        ('Natuzzi',  'Editions'),
        ('Hay',      'Basic')
       ) AS v(brand, name)
  JOIN catalog.brands b ON b.name = v.brand;

-- ============================================================================
--  สินค้า — กระเบื้อง
--  ขนาดจริงของกระเบื้องอยู่ที่ tile_specs ช่อง width/length/height ที่นี่จึงเว้นว่าง
-- ============================================================================
-- category_id หยิบมาจาก subcategories.category_id ตรง ๆ — คู่ (หมวดหลัก, หมวดย่อย)
-- จึงไม่มีทางไม่ตรงกัน และ composite FK ก็ผ่านแน่นอน
INSERT INTO catalog.products
       (sku, product_type, brand_id, collection_id, category_id, subcategory_id,
        name, description, status, discontinued_at)
SELECT v.sku, 'tile', b.id, c.id, sub.category_id, sub.id, v.name, v.descr,
       v.status::catalog.item_status,
       CASE WHEN v.status = 'discontinued' THEN now() - interval '2 months' END
  FROM (VALUES
        ('TILE-6060-GRY', 'Cotto',    'Stone', 'Floor Tile',
         'Stone Grey 60x60',
         'กระเบื้องพื้นแกรนิตโต้ ผิวด้าน สีเทาลายหิน เหมาะกับพื้นภายในและระเบียง', 'active'),

        ('TILE-3060-WHT', 'Duragres', 'Pure',  'Wall Tile',
         'Pure White 30x60',
         'กระเบื้องผนังผิวมัน สีขาวเรียบ ใช้ได้ทั้งห้องน้ำและห้องครัว', 'active'),

        ('GRA-8080-BLK',  'Cotto',    'Luxe',  'Floor Tile',
         'Luxe Black Marble 80x80',
         'แกรนิตโต้ขัดเงา ลายหินอ่อนสีดำ เส้นลายต่อเนื่องแบบ Bookmatch', 'active'),

        ('TRIM-60-GRY',   'Sosuco',   'Line',  'Trim',
         'Line Trim 6x60',
         'กระเบื้องบัว/คิ้ว ใช้ปิดขอบพื้นและมุมผนัง ขายเป็นเมตร', 'active'),

        ('DEC-3030-ART',  'Campana',  'Art',   'Decor',
         'Art Pattern 30x30',
         'กระเบื้องลายตกแต่ง พิมพ์ลายดิจิทัล ใช้ทำแผงตกแต่งผนัง ขายเป็นชิ้น', 'active'),

        -- เลิกผลิตแล้ว — sales ค้นไม่เจอ แต่ใบ OC เก่ายังอ้างถึงได้
        ('TILE-3030-OLD', 'Sosuco',   'Line',  'Floor Tile',
         'Line Classic 30x30',
         'รุ่นเดิมที่โรงงานเลิกผลิต เก็บไว้อ้างอิงใบเก่า', 'discontinued')
       ) AS v(sku, brand, coll, subcat, name, descr, status)
  JOIN catalog.brands        b   ON b.name = v.brand
  JOIN catalog.collections   c   ON c.name = v.coll AND c.brand_id = b.id
  JOIN catalog.subcategories sub ON sub.name = v.subcat;

-- ============================================================================
--  สินค้า — เฟอร์นิเจอร์ (ขนาดอยู่ที่ products เพราะไม่มีตารางขยายเรื่องขนาด)
-- ============================================================================
INSERT INTO catalog.products
       (sku, product_type, brand_id, collection_id, category_id, subcategory_id,
        name, description, width_cm, length_cm, height_cm, default_qty_unit)
SELECT v.sku, 'furniture', b.id, c.id, sub.category_id, sub.id, v.name, v.descr,
       v.w, v.l, v.h, v.unit
  FROM (VALUES
        ('FUR-TBL-001', 'Botempi', 'Core',     'Coffee Table',
         'Coffee Table Nordic',
         'โต๊ะกลางไม้จริง ท็อปหนา 25 มม. ขาเหล็กพ่นสีฝุ่น รับน้ำหนักได้ 80 กก.',
         120.00, 60.00, 42.00, 'ตัว'),

        ('FUR-SOF-003', 'Natuzzi', 'Editions', '3 Seater',
         'Sofa Milano 3 Seater',
         'โซฟา 3 ที่นั่ง โครงไม้ยางพารา เบาะฟองน้ำอัดความหนาแน่นสูง สั่งผลิต 60-90 วัน',
         210.00, 92.00, 85.00, 'ชุด'),

        ('FUR-CHR-012', 'Hay',     'Basic',    'Dining Chair',
         'Dining Chair Oslo',
         'เก้าอี้ทานอาหาร เบาะหุ้มผ้า ขาไม้บีชแท้ ซ้อนเก็บได้',
         46.00, 52.00, 81.00, 'ชิ้น')
       ) AS v(sku, brand, coll, subcat, name, descr, w, l, h, unit)
  JOIN catalog.brands        b   ON b.name = v.brand
  JOIN catalog.collections   c   ON c.name = v.coll AND c.brand_id = b.id
  JOIN catalog.subcategories sub ON sub.name = v.subcat;

-- ============================================================================
--  สเปกกระเบื้อง — ตัวขับสูตรคำนวณทั้งหมดในใบ OC
--  ตร.ม./แผ่น = sqm_per_box / pieces_per_box  เช่น 1.08 / 3 = 0.36
-- ============================================================================
INSERT INTO catalog.tile_specs
       (product_id, item, color, surface,
        sale_w_cm, sale_l_cm, sale_h_cm, work_w_cm, work_l_cm, work_h_cm,
        price_unit, price_per_unit, sqm_per_box, pieces_per_box, kg_per_box)
SELECT p.id, v.item, v.color, v.surface,
       v.sw, v.sl, v.sh, v.ww, v.wl, v.wh,
       v.unit::catalog.price_unit, v.price, v.sqm_box, v.pcs_box, v.kg_box
  FROM (VALUES
        --  sku              item      สี         ผิว       ขนาดขาย W  L   H     ขนาดจริง W   L     H     U.M.    ราคา  ตร.ม./กล่อง ชิ้น/กล่อง กก./กล่อง
        ('TILE-6060-GRY', 'Stone',   'Grey',   'ด้าน',   60.00, 60.00, 0.90, 59.50, 59.50, 0.90, 'sqm',    2100.00, 1.0800,  3.0000, 21.2300),
        ('TILE-3060-WHT', 'Plain',   'White',  'มัน',    30.00, 60.00, 0.85, 29.70, 59.70, 0.85, 'sqm',     850.00, 1.4400,  8.0000, 19.5000),
        ('GRA-8080-BLK',  'Marble',  'Black',  'ขัดเงา', 80.00, 80.00, 1.05, 79.60, 79.60, 1.05, 'sqm',    3600.00, 1.2800,  2.0000, 33.0000),
        -- ขายเป็นเมตร: ต้องมี sale_l_cm ไม่งั้น CHECK ไม่ผ่าน (60 ซม. = 0.6 ม./ชิ้น)
        ('TRIM-60-GRY',   'Stone',   'Grey',   'ด้าน',    6.00, 60.00, 0.90,  6.00, 60.00, 0.90, 'meter',   180.00, 0.3600, 10.0000,  8.0000),
        -- ขายเป็นชิ้น: ราคาผูกกับแผ่น ไม่ใช่พื้นที่
        ('DEC-3030-ART',  'Pattern', 'Multi',  'ด้าน',   30.00, 30.00, 0.80, 29.70, 29.70, 0.80, 'piece',   120.00, 0.9900, 11.0000, 14.0000),
        ('TILE-3030-OLD', 'Plain',   'Beige',  'ด้าน',   30.00, 30.00, 0.80, 29.70, 29.70, 0.80, 'sqm',     690.00, 1.0800, 12.0000, 16.0000)
       ) AS v(sku, item, color, surface, sw, sl, sh, ww, wl, wh, unit, price, sqm_box, pcs_box, kg_box)
  JOIN catalog.products p ON p.sku = v.sku;

-- ============================================================================
--  ตัวเลือกเฟอร์นิเจอร์ — 1 ตัวเลือก = 1 รูปแบบที่มีราคาเดียว
-- ============================================================================
INSERT INTO catalog.product_options (product_id, label, price, sort_order)
SELECT p.id, v.label, v.price, v.ord
  FROM (VALUES
        ('FUR-TBL-001', 'GreyWood',      24500.00, 1),
        ('FUR-TBL-001', 'Black Oak',     27800.00, 2),

        ('FUR-SOF-003', 'Linen Beige',   89000.00, 1),
        ('FUR-SOF-003', 'Full Grain',   145000.00, 2),
        ('FUR-SOF-003', 'Velvet Green',  98000.00, 3),

        ('FUR-CHR-012', 'Cream',          4900.00, 1),
        ('FUR-CHR-012', 'Dark Grey',      5400.00, 2)
       ) AS v(sku, label, price, ord)
  JOIN catalog.products p ON p.sku = v.sku;

-- ============================================================================
--  ชิ้นส่วนในแต่ละตัวเลือก — ไปโผล่ในบล็อก DESCRIPTION ของใบ OC ตามลำดับนี้
-- ============================================================================
INSERT INTO catalog.option_parts (option_id, title, sub_description, sort_order)
SELECT o.id, v.title, v.sub, v.ord
  FROM (VALUES
        -- โต๊ะกลาง ตัวเลือกที่ 1
        ('FUR-TBL-001', 1, 'Top',         'GreyWood ผิวเมลามีน',        1),
        ('FUR-TBL-001', 1, 'Base',        'เหล็กพ่นสีดำด้าน',            2),
        -- โต๊ะกลาง ตัวเลือกที่ 2
        ('FUR-TBL-001', 2, 'Top',         'Black Oak Veneer',           1),
        ('FUR-TBL-001', 2, 'Base',        'เหล็กพ่นสีดำด้าน',            2),
        ('FUR-TBL-001', 2, 'Legs',        'ปลายขาไม้โอ๊คแท้',            3),

        -- โซฟา ตัวเลือกที่ 1
        ('FUR-SOF-003', 1, 'Upholstery',  'ผ้า Linen สี Beige',         1),
        ('FUR-SOF-003', 1, 'Frame',       'ไม้ยางพาราอบแห้ง',           2),
        ('FUR-SOF-003', 1, 'Legs',        'ไม้วอลนัท',                  3),
        -- โซฟา ตัวเลือกที่ 2
        ('FUR-SOF-003', 2, 'Upholstery',  'หนังแท้ Full Grain สีดำ',    1),
        ('FUR-SOF-003', 2, 'Frame',       'ไม้ยางพาราอบแห้ง',           2),
        ('FUR-SOF-003', 2, 'Legs',        'สแตนเลสเงา',                 3),
        -- โซฟา ตัวเลือกที่ 3
        ('FUR-SOF-003', 3, 'Upholstery',  'ผ้ากำมะหยี่สีเขียว',          1),
        ('FUR-SOF-003', 3, 'Frame',       'ไม้ยางพาราอบแห้ง',           2),
        ('FUR-SOF-003', 3, 'Legs',        'ทองเหลืองรมดำ',              3),

        -- เก้าอี้ ตัวเลือกที่ 1
        ('FUR-CHR-012', 1, 'Seat',        'ผ้าสีครีม',                  1),
        ('FUR-CHR-012', 1, 'Legs',        'ไม้บีชสีธรรมชาติ',            2),
        -- เก้าอี้ ตัวเลือกที่ 2
        ('FUR-CHR-012', 2, 'Seat',        'ผ้าสีเทาเข้ม',               1),
        ('FUR-CHR-012', 2, 'Legs',        'ไม้บีชย้อมสีวอลนัท',          2)
       ) AS v(sku, opt, title, sub, ord)
  JOIN catalog.products        p ON p.sku = v.sku
  JOIN catalog.product_options o ON o.product_id = p.id AND o.sort_order = v.opt;

-- ============================================================================
--  รูปสินค้า — เก็บเป็น object key ไม่ใช่ data URL
--  option_id ว่าง = รูปหลักของสินค้า, มีค่า = รูปเฉพาะของตัวเลือกนั้น
-- ============================================================================

-- รูปหลักของทุกสินค้า
INSERT INTO catalog.product_images (product_id, option_id, file_path, caption, is_primary, sort_order)
SELECT p.id, NULL, v.path, v.caption, true, 0
  FROM (VALUES
        ('TILE-6060-GRY', 'products/tile-6060-gry/main.jpg', 'ภาพปูจริง มุมห้องนั่งเล่น'),
        ('TILE-3060-WHT', 'products/tile-3060-wht/main.jpg', 'ภาพแผ่นเดี่ยว'),
        ('GRA-8080-BLK',  'products/gra-8080-blk/main.jpg',  'ลาย Bookmatch 4 แผ่นต่อกัน'),
        ('TRIM-60-GRY',   'products/trim-60-gry/main.jpg',   NULL),
        ('DEC-3030-ART',  'products/dec-3030-art/main.jpg',  'แผงตกแต่ง 9 แผ่น'),
        ('TILE-3030-OLD', 'products/tile-3030-old/main.jpg', NULL),
        ('FUR-TBL-001',   'products/fur-tbl-001/main.jpg',   'จัดวางคู่โซฟา'),
        ('FUR-SOF-003',   'products/fur-sof-003/main.jpg',   'มุมเฉียง 45 องศา'),
        ('FUR-CHR-012',   'products/fur-chr-012/main.jpg',   NULL)
       ) AS v(sku, path, caption)
  JOIN catalog.products p ON p.sku = v.sku;

-- รูปเพิ่มเติมของสินค้า (ไม่ใช่รูปหลัก) — ทดสอบการเรียงลำดับในแกลเลอรี
INSERT INTO catalog.product_images (product_id, option_id, file_path, caption, is_primary, sort_order)
SELECT p.id, NULL, v.path, v.caption, false, v.ord
  FROM (VALUES
        ('GRA-8080-BLK', 'products/gra-8080-blk/detail-vein.jpg', 'รายละเอียดเส้นลาย',      1),
        ('GRA-8080-BLK', 'products/gra-8080-blk/room.jpg',        'ห้องโถงต้อนรับ',          2),
        ('FUR-TBL-001',  'products/fur-tbl-001/detail-leg.jpg',   'จุดต่อขาเหล็กกับท็อปไม้', 1)
       ) AS v(sku, path, caption, ord)
  JOIN catalog.products p ON p.sku = v.sku;

-- รูปประจำตัวเลือก — โชว์รวมในแกลเลอรีเดียวกับรูปหลัก
INSERT INTO catalog.product_images (product_id, option_id, file_path, caption, is_primary, sort_order)
SELECT p.id, o.id, v.path, v.caption, false, v.ord
  FROM (VALUES
        ('FUR-SOF-003', 1, 'products/fur-sof-003/opt-linen.jpg',  'ตัวอย่างผ้า Linen สี Beige', 10),
        ('FUR-SOF-003', 2, 'products/fur-sof-003/opt-leather.jpg','ตัวอย่างหนังแท้สีดำ',        11),
        ('FUR-SOF-003', 3, 'products/fur-sof-003/opt-velvet.jpg', 'ตัวอย่างผ้ากำมะหยี่สีเขียว',  12)
       ) AS v(sku, opt, path, caption, ord)
  JOIN catalog.products        p ON p.sku = v.sku
  JOIN catalog.product_options o ON o.product_id = p.id AND o.sort_order = v.opt;

-- ============================================================================
--  ประวัติราคาที่ย้ายมาจากระบบเก่า (ก่อนมีระบบนี้)
--  แถวพวกนี้ใส่มือ เพราะ trigger เขียนให้เฉพาะตอน UPDATE ในระบบใหม่เท่านั้น
-- ============================================================================
INSERT INTO catalog.price_history (product_id, old_price, new_price, changed_at, changed_by, note)
SELECT p.id, v.old_p, v.new_p, v.at::timestamptz,
       '3f1c8a6e-2b7d-4c91-9a55-0c2f7e8d1b40'::uuid, v.note
  FROM (VALUES
        ('TILE-6060-GRY', NULL::numeric, 1950.00, '2025-01-15 09:00+07', 'ราคาตั้งต้นตอนย้ายข้อมูลจากไฟล์ Excel'),
        ('TILE-6060-GRY', 1950.00,       2100.00, '2025-07-01 10:30+07', 'ปรับตามราคาโรงงานรอบกลางปี'),
        ('GRA-8080-BLK',  NULL,          3600.00, '2025-01-15 09:00+07', 'ราคาตั้งต้นตอนย้ายข้อมูลจากไฟล์ Excel')
       ) AS v(sku, old_p, new_p, at, note)
  JOIN catalog.products p ON p.sku = v.sku;

-- ============================================================================
--  การเปลี่ยนราคาในระบบใหม่ — ไม่ต้อง INSERT price_history เอง
--  trigger tile_price_hist / option_price_hist เขียนให้อัตโนมัติ
-- ============================================================================
SET LOCAL app.note = 'ปรับราคาตามต้นทุนนำเข้ารอบ Q3/2569';

UPDATE catalog.tile_specs ts
   SET price_per_unit = 2250.00
  FROM catalog.products p
 WHERE p.id = ts.product_id AND p.sku = 'TILE-6060-GRY';   -- 2,100 → 2,250

UPDATE catalog.product_options o
   SET price = 92000.00
  FROM catalog.products p
 WHERE p.id = o.product_id AND p.sku = 'FUR-SOF-003' AND o.sort_order = 1;  -- 89,000 → 92,000

COMMIT;

-- ============================================================================
--  ตรวจผล
-- ============================================================================

-- นับแถวทุกตาราง
SELECT 'brands'          AS table_name, count(*) FROM catalog.brands
UNION ALL SELECT 'categories',      count(*) FROM catalog.categories
UNION ALL SELECT 'subcategories',   count(*) FROM catalog.subcategories
UNION ALL SELECT 'collections',     count(*) FROM catalog.collections
UNION ALL SELECT 'products',        count(*) FROM catalog.products
UNION ALL SELECT 'product_images',  count(*) FROM catalog.product_images
UNION ALL SELECT 'tile_specs',      count(*) FROM catalog.tile_specs
UNION ALL SELECT 'product_options', count(*) FROM catalog.product_options
UNION ALL SELECT 'option_parts',    count(*) FROM catalog.option_parts
UNION ALL SELECT 'price_history',   count(*) FROM catalog.price_history
ORDER BY 1;

-- สิ่งที่ sales เห็นในช่องค้นหา — TILE-3030-OLD ต้องไม่โผล่
SELECT sku, product_type, name, brand_name, subcategory_name, display_price, price_unit
  FROM catalog.product_search
 WHERE status = 'active'
 ORDER BY product_type, sku;

-- ประวัติราคาของกระเบื้องตัวที่ขึ้นราคา — แถวสุดท้ายมาจาก trigger
SELECT h.changed_at, h.old_price, h.new_price, h.note
  FROM catalog.price_history h
  JOIN catalog.products p ON p.id = h.product_id
 WHERE p.sku = 'TILE-6060-GRY'
 ORDER BY h.changed_at;

-- ตัวเลือกพร้อมชิ้นส่วน แบบที่จะเอาไปขึ้นใบ OC
SELECT p.sku, o.sort_order AS "ตัวเลือกที่", o.price,
       string_agg(op.title || ': ' || op.sub_description, ' | ' ORDER BY op.sort_order) AS parts
  FROM catalog.products p
  JOIN catalog.product_options o ON o.product_id = p.id
  LEFT JOIN catalog.option_parts op ON op.option_id = o.id
 WHERE p.product_type = 'furniture'
 GROUP BY p.sku, o.sort_order, o.price
 ORDER BY p.sku, o.sort_order;
