SELECT
  a.total_stock AS initial_stock,
  sv.stock AS database_remaining,
  (SELECT COUNT(*) FROM tb_voucher_order o WHERE o.voucher_id = a.voucher_id) AS successful_orders,
  (SELECT COUNT(*) FROM tb_seckill_reservation r
     WHERE r.voucher_id = a.voucher_id AND r.state = 'PROCESSING') AS processing_reservations,
  (SELECT COUNT(*) FROM tb_seckill_reservation r
     WHERE r.voucher_id = a.voucher_id AND r.state = 'FAILED') AS failed_reservations,
  (SELECT COUNT(*) FROM tb_seckill_reservation r
     WHERE r.voucher_id = a.voucher_id AND r.state = 'REVIEW') AS review_reservations,
  (SELECT COUNT(*) FROM tb_seckill_reservation r
     WHERE r.voucher_id = a.voucher_id AND r.state IN ('PROCESSING', 'REVIEW')) AS unresolved_reservations,
  (SELECT COUNT(*) FROM (
     SELECT o.user_id FROM tb_voucher_order o
     WHERE o.voucher_id = a.voucher_id
     GROUP BY o.user_id HAVING COUNT(*) > 1
   ) duplicates) AS one_user_multiple_order_violations,
  (SELECT COUNT(*) FROM tb_business_outbox b
     WHERE b.state IN ('PENDING', 'SENDING')) AS outbox_pending_or_inflight,
  (SELECT COUNT(*) FROM tb_business_outbox b WHERE b.state = 'REVIEW') AS outbox_review,
  (SELECT COUNT(*) FROM tb_seckill_dead_letter) AS seckill_dead_letters,
  (SELECT COUNT(*) FROM tb_message_failure) AS message_failures
FROM tb_seckill_activity a
JOIN tb_seckill_voucher sv ON sv.voucher_id = a.voucher_id
WHERE a.voucher_id = @perf_voucher_id;
