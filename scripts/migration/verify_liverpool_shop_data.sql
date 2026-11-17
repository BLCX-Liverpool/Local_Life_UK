SELECT COUNT(*) AS liverpool_shop_count
FROM tb_shop
WHERE id BETWEEN 900001 AND 900059;

SELECT type_id, COUNT(*) AS shop_count
FROM tb_shop
WHERE id BETWEEN 900001 AND 900059
GROUP BY type_id
ORDER BY type_id;

SELECT id, name, type_id
FROM tb_shop
WHERE id IN (900046, 900047, 900058, 900059)
ORDER BY id;

SELECT id, name, x, y
FROM tb_shop
WHERE id BETWEEN 900001 AND 900059
  AND (x >= 0 OR y <= 0 OR x < -180 OR y > 90);

SELECT id, name, CHAR_LENGTH(open_hours) AS open_hours_length
FROM tb_shop
WHERE id BETWEEN 900001 AND 900059
  AND CHAR_LENGTH(open_hours) > 128;

SELECT s.id, s.name, s.type_id
FROM tb_shop s
LEFT JOIN tb_shop_type t ON t.id = s.type_id
WHERE s.id BETWEEN 900001 AND 900059
  AND t.id IS NULL;

SELECT COUNT(*) AS remaining_legacy_shop_count
FROM tb_shop
WHERE id BETWEEN 1 AND 14;
