-- Run only after a database backup and after Flyway has imported the Liverpool catalog.
-- This script is repeatable: it targets only the original course demo record IDs.
SET NAMES utf8mb4;
START TRANSACTION;

DELETE FROM tb_blog_comments WHERE blog_id IN (4, 5, 6, 7);
DELETE FROM tb_blog_like WHERE blog_id IN (4, 5, 6, 7);
DELETE FROM tb_blog_media WHERE blog_id IN (4, 5, 6, 7);
DELETE FROM tb_blog WHERE id IN (4, 5, 6, 7);

-- Keep the original demonstration voucher usable without touching later vouchers.
UPDATE tb_voucher
SET shop_id = 900001,
    title = '£50代金券'
WHERE id = 1
  AND shop_id = 1;

DELETE FROM tb_shop WHERE id BETWEEN 1 AND 14;

COMMIT;

SELECT COUNT(*) AS liverpool_shop_count
FROM tb_shop
WHERE id BETWEEN 900001 AND 900059;

SELECT COUNT(*) AS remaining_legacy_shop_count
FROM tb_shop
WHERE id BETWEEN 1 AND 14;

SELECT id, shop_id, title
FROM tb_voucher
WHERE id = 1;
