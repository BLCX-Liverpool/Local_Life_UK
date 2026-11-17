# 利物浦店铺数据迁移

`liverpool_shops_with_coords_images.json` 是生成数据库迁移 SQL 的主数据源。CSV 用于通用交换，XLSX 保留人工核验、图片来源和坐标说明。三份主数据必须保持一致。

## 数据约定

- 店铺 ID 使用 `900001` 到 `900059`。
- `x` 是经度，利物浦为负数；`y` 是纬度。
- `avg_price` 是整数英镑/人。
- 未知字段保留为空值，不用 `0` 代替未知评分、评论或销量。
- `type_id=4` 是健身运动，`type_id=10` 是美睫·美甲。
- 图片暂时允许使用远程链接；缺失图片由前端显示“暂无图片”。

## 更新迁移 SQL

修改 JSON 后，在项目根目录执行：

```bash
node scripts/migration/generate_liverpool_shop_sql.mjs
```

生成结果为 `src/main/resources/db/migration/R__liverpool_shop_catalog.sql`。Flyway 会在文件校验和变化后重新执行，并按店铺 ID 幂等更新。

## 现有环境切换顺序

### 1. 备份

在项目根目录执行：

```bash
mkdir -p backups
docker compose -p hm-dianping -f dev/docker-compose.yml up -d --wait mysql
docker compose -p hm-dianping -f dev/docker-compose.yml exec -T mysql \
  mysqldump -uroot -phmdp_local_only --single-transaction hmdp \
  > backups/hmdp-before-liverpool.sql
```

### 2. 导入结构与店铺数据

```bash
docker compose -p hm-dianping -f dev/docker-compose.yml up -d
docker compose -p hm-dianping -f dev/docker-compose.yml logs -f java
```

日志出现应用启动成功后退出日志跟踪。Flyway 会依次执行 `V10__adapt_shop_for_uk_catalog.sql` 和 `R__liverpool_shop_catalog.sql`。

### 3. 切换旧演示数据

```bash
docker compose -p hm-dianping -f dev/docker-compose.yml exec -T mysql \
  mysql --default-character-set=utf8mb4 -uroot -phmdp_local_only hmdp \
  < scripts/migration/cutover_liverpool_demo.sql
```

这一步只移除原课程的店铺与探店笔记，并把原始 1 号演示券迁到首家利物浦店铺。

### 4. 校验

```bash
docker compose -p hm-dianping -f dev/docker-compose.yml exec -T mysql \
  mysql --default-character-set=utf8mb4 -uroot -phmdp_local_only hmdp \
  < scripts/migration/verify_liverpool_shop_data.sql
```

预期店铺数是 59：美食 41 家，其他 9 类每类 2 家；旧店铺数是 0；异常坐标、过长营业时间和缺失分类的查询都应返回空集。

### 5. 刷新 Redis 并重启应用

```bash
./scripts/migration/rebuild_liverpool_shop_geo.sh
docker compose -p hm-dianping -f dev/docker-compose.yml restart java web
```

### 6. 页面验收

打开 `http://127.0.0.1:8080`，确认首页显示利物浦图片和城市名，金额使用 `£`，10 个分类都有店铺，缺图店铺显示“暂无图片”。

历史订单和后续创建的优惠券不在清理脚本中删除，避免破坏订单快照。只会重新绑定原始 1 号演示券。
