package com.hmdp.messaging;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.hmdp.service.IBusinessEventService;
import com.hmdp.service.impl.BusinessEventServiceImpl;
import com.rabbitmq.client.Channel;
import io.micrometer.core.instrument.MeterRegistry;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import javax.annotation.PreDestroy;
import lombok.extern.slf4j.Slf4j;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.core.MessageDeliveryMode;
import org.springframework.amqp.core.MessageProperties;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.amqp.rabbit.connection.CorrelationData;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnExpression;
import org.springframework.context.event.ContextRefreshedEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

/** RabbitMQ transport using quorum queues, confirms, returns and manual acknowledgements. */
@Slf4j
@Component
@ConditionalOnExpression(
    "${hmdp.mq.enabled:false} and '${hmdp.mq.provider:rocketmq}' == 'rabbitmq'")
public class RabbitMqTransport implements EventPublisher {
  private static final String DELIVERY_COUNT = "x-delivery-count";
  private static final String DELIVERY_TIME = "x-opt-delivery-time";

  private final ObjectMapper json;
  private final IBusinessEventService handler;
  private final MeterRegistry metrics;
  private final RabbitTemplate rabbit;
  private final AtomicInteger connected = new AtomicInteger();

  @Value("${hmdp.mq.rabbitmq.business-exchange:hmdp.business}")
  private String businessExchange;

  @Value("${hmdp.mq.rabbitmq.deadline-exchange:hmdp.deadline}")
  private String deadlineExchange;

  @Value("${hmdp.mq.send-timeout-ms:3000}")
  private int timeout;

  public RabbitMqTransport(
      ObjectMapper json,
      IBusinessEventService handler,
      MeterRegistry metrics,
      RabbitTemplate rabbit) {
    this.json = json;
    this.handler = handler;
    this.metrics = metrics;
    this.rabbit = rabbit;
    metrics.gauge("hmdp.mq.client.started", connected);
  }

  @EventListener(ContextRefreshedEvent.class)
  public void start() {
    if (!rabbit.getConnectionFactory().createConnection().isOpen()) {
      throw new IllegalStateException("RabbitMQ 连接尚未打开");
    }
    connected.set(1);
  }

  @Override
  public void publish(BusinessEvent event) {
    if (connected.get() == 0) {
      throw new IllegalStateException("RabbitMQ 客户端尚未启动");
    }
    String group = BusinessEventServiceImpl.resolveConsumerGroup(event.getKind());
    String attemptId = UUID.randomUUID().toString();
    try {
      MessageProperties properties = new MessageProperties();
      properties.setDeliveryMode(MessageDeliveryMode.PERSISTENT);
      properties.setContentType(MessageProperties.CONTENT_TYPE_JSON);
      properties.setContentEncoding(StandardCharsets.UTF_8.name());
      properties.setMessageId(attemptId);
      properties.setCorrelationId("outbox:" + event.getEventId());
      properties.setHeader("eventId", event.getEventId());
      properties.setHeader("aggregateId", event.getAggregateId());
      if (event.getDeliverAt() != null && event.getDeliverAt() > System.currentTimeMillis()) {
        properties.setHeader(DELIVERY_TIME, event.getDeliverAt());
      }
      Message message = new Message(json.writeValueAsBytes(event), properties);
      CorrelationData correlation = new CorrelationData(attemptId);
      rabbit.send(
          "deadlines".equals(group) ? deadlineExchange : businessExchange,
          event.getKind(),
          message,
          correlation);
      CorrelationData.Confirm confirm =
          correlation.getFuture().get(Math.max(1, timeout), TimeUnit.MILLISECONDS);
      if (correlation.getReturnedMessage() != null) {
        throw new IllegalStateException("RabbitMQ 未将消息路由到队列");
      }
      if (!confirm.isAck()) {
        throw new IllegalStateException("RabbitMQ Broker NACK: " + confirm.getReason());
      }
    } catch (InterruptedException failure) {
      Thread.currentThread().interrupt();
      throw new IllegalStateException("RabbitMQ 发布确认等待被中断", failure);
    } catch (Exception failure) {
      throw new IllegalStateException("RabbitMQ 投递结果未确认", failure);
    }
  }

  @RabbitListener(
      queues = "${hmdp.mq.rabbitmq.queue-prefix:hmdp}.feed",
      autoStartup = "${hmdp.mq.rabbitmq.consumer-enabled:true}")
  public void consumeFeed(Message message, Channel channel) throws Exception {
    consume(message, channel, "feed");
  }

  @RabbitListener(
      queues = "${hmdp.mq.rabbitmq.queue-prefix:hmdp}.relations",
      autoStartup = "${hmdp.mq.rabbitmq.consumer-enabled:true}")
  public void consumeRelations(Message message, Channel channel) throws Exception {
    consume(message, channel, "relations");
  }

  @RabbitListener(
      queues = "${hmdp.mq.rabbitmq.queue-prefix:hmdp}.media",
      autoStartup = "${hmdp.mq.rabbitmq.consumer-enabled:true}")
  public void consumeMedia(Message message, Channel channel) throws Exception {
    consume(message, channel, "media");
  }

  @RabbitListener(
      queues = "${hmdp.mq.rabbitmq.queue-prefix:hmdp}.cache",
      autoStartup = "${hmdp.mq.rabbitmq.consumer-enabled:true}")
  public void consumeCache(Message message, Channel channel) throws Exception {
    consume(message, channel, "cache");
  }

  @RabbitListener(
      queues = "${hmdp.mq.rabbitmq.queue-prefix:hmdp}.activities",
      autoStartup = "${hmdp.mq.rabbitmq.consumer-enabled:true}")
  public void consumeActivities(Message message, Channel channel) throws Exception {
    consume(message, channel, "activities");
  }

  @RabbitListener(
      queues = "${hmdp.mq.rabbitmq.queue-prefix:hmdp}.fulfillment",
      autoStartup = "${hmdp.mq.rabbitmq.consumer-enabled:true}")
  public void consumeFulfillment(Message message, Channel channel) throws Exception {
    consume(message, channel, "fulfillment");
  }

  @RabbitListener(
      queues = "${hmdp.mq.rabbitmq.queue-prefix:hmdp}.orders",
      autoStartup = "${hmdp.mq.rabbitmq.consumer-enabled:true}")
  public void consumeOrders(Message message, Channel channel) throws Exception {
    consume(message, channel, "orders");
  }

  @RabbitListener(
      queues = "${hmdp.mq.rabbitmq.queue-prefix:hmdp}.deadlines",
      autoStartup = "${hmdp.mq.rabbitmq.consumer-enabled:true}")
  public void consumeDeadlines(Message message, Channel channel) throws Exception {
    consume(message, channel, "deadlines");
  }

  private void consume(Message message, Channel channel, String group) throws Exception {
    long deliveryTag = message.getMessageProperties().getDeliveryTag();
    String payload = new String(message.getBody(), StandardCharsets.UTF_8);
    BusinessEvent event = null;
    try {
      event = json.readValue(payload, BusinessEvent.class);
      handler.consume(event, group);
    } catch (Exception failure) {
      RuntimeException error =
          failure instanceof RuntimeException
              ? (RuntimeException) failure
              : new IllegalArgumentException("消息格式错误", failure);
      metrics.counter("hmdp.mq.consumptions", "group", group, "result", "retry").increment();
      try {
        if (handler.recordConsumptionFailure(
            event,
            group,
            brokerMessageId(message),
            payload,
            error,
            currentDelivery(message))) {
          channel.basicAck(deliveryTag, false);
          return;
        }
      } catch (RuntimeException storageFailure) {
        log.warn("RabbitMQ 消息 {} 的失败状态尚未持久化，保持重试", brokerMessageId(message));
      }
      // basic.reject is intentional: quorum queues increment x-delivery-count for reject,
      // while basic.nack does not represent a failed delivery in RabbitMQ 4.4.
      channel.basicReject(deliveryTag, true);
      return;
    }
    channel.basicAck(deliveryTag, false);
  }

  private static int currentDelivery(Message message) {
    Object count = message.getMessageProperties().getHeaders().get(DELIVERY_COUNT);
    long failures = count instanceof Number ? ((Number) count).longValue() : 0;
    return (int) Math.min(Integer.MAX_VALUE, failures + 1);
  }

  private static String brokerMessageId(Message message) {
    String id = message.getMessageProperties().getMessageId();
    return id == null ? "rabbit:" + UUID.randomUUID() : id;
  }

  @PreDestroy
  public void stop() {
    connected.set(0);
  }
}
