-- This script is only for the isolated hmdp-perf Compose project.
-- Required session variables:
--   @perf_user_count, @perf_stock, @perf_voucher_id

SET @database_guard = DATABASE();

DROP PROCEDURE IF EXISTS perf_require_test_database;
DELIMITER //
CREATE PROCEDURE perf_require_test_database()
BEGIN
  IF @database_guard <> 'hmdp_optimization_test' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Refusing to reset a non-performance database';
  END IF;
END//
DELIMITER ;
CALL perf_require_test_database();
DROP PROCEDURE perf_require_test_database;

DELETE FROM tb_message_inbox;
DELETE FROM tb_message_failure;
DELETE FROM tb_business_outbox;
DELETE FROM tb_seckill_dead_letter;
DELETE FROM tb_seckill_reservation;
DELETE FROM tb_voucher_order WHERE voucher_id = @perf_voucher_id;
DELETE FROM tb_seckill_activity WHERE voucher_id = @perf_voucher_id;
DELETE FROM tb_seckill_voucher WHERE voucher_id = @perf_voucher_id;
DELETE FROM tb_voucher WHERE id = @perf_voucher_id;
DELETE FROM tb_user_info WHERE user_id BETWEEN 900001 AND 910000;
DELETE FROM tb_user WHERE id BETWEEN 900001 AND 910000;

DROP PROCEDURE IF EXISTS perf_seed_users;
DELIMITER //
CREATE PROCEDURE perf_seed_users(IN requested_users INT)
BEGIN
  DECLARE i INT DEFAULT 1;
  IF requested_users < 1 OR requested_users > 10000 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User count must be between 1 and 10000';
  END IF;
  WHILE i <= requested_users DO
    INSERT INTO tb_user(id, phone, password, nick_name, icon)
    VALUES(
      900000 + i,
      CONCAT('199', LPAD(i, 8, '0')),
      '',
      CONCAT('perf-user-', LPAD(i, 5, '0')),
      ''
    );
    SET i = i + 1;
  END WHILE;
END//
DELIMITER ;

CALL perf_seed_users(@perf_user_count);
DROP PROCEDURE perf_seed_users;

INSERT INTO tb_voucher(
  id, shop_id, title, sub_title, rules, pay_value, actual_value, type, status
) VALUES(
  @perf_voucher_id,
  1,
  '【压测专用】秒杀券',
  '仅限隔离压测环境',
  '压测数据，不用于真实交易',
  0,
  100,
  1,
  1
);

INSERT INTO tb_seckill_voucher(voucher_id, stock, begin_time, end_time)
VALUES(
  @perf_voucher_id,
  @perf_stock,
  TIMESTAMPADD(HOUR, -1, NOW()),
  TIMESTAMPADD(DAY, 1, NOW())
);

INSERT INTO tb_seckill_activity(voucher_id, total_stock, has_published)
VALUES(@perf_voucher_id, @perf_stock, 0);

