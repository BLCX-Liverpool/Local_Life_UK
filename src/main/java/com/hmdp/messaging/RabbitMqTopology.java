package com.hmdp.messaging;

import java.util.ArrayList;
import java.util.List;
import org.springframework.amqp.core.BindingBuilder;
import org.springframework.amqp.core.Declarable;
import org.springframework.amqp.core.Declarables;
import org.springframework.amqp.core.DirectExchange;
import org.springframework.amqp.core.Queue;
import org.springframework.amqp.core.QueueBuilder;
import org.springframework.amqp.core.TopicExchange;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnExpression;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** RabbitMQ exchanges, quorum queues and exact business event bindings. */
@Configuration
@ConditionalOnExpression(
    "${hmdp.mq.enabled:false} and '${hmdp.mq.provider:rocketmq}' == 'rabbitmq'")
public class RabbitMqTopology {
  @Value("${hmdp.mq.rabbitmq.business-exchange:hmdp.business}")
  private String businessExchangeName;

  @Value("${hmdp.mq.rabbitmq.deadline-exchange:hmdp.deadline}")
  private String deadlineExchangeName;

  @Value("${hmdp.mq.rabbitmq.queue-prefix:hmdp}")
  private String queuePrefix;

  @Bean
  public Declarables rabbitMqDeclarables() {
    TopicExchange business = new TopicExchange(businessExchangeName, true, false);
    DirectExchange deadline = new DirectExchange(deadlineExchangeName, true, false);
    Queue feed = quorumQueue("feed");
    Queue relations = quorumQueue("relations");
    Queue media = quorumQueue("media");
    Queue cache = quorumQueue("cache");
    Queue activities = quorumQueue("activities");
    Queue fulfillment = quorumQueue("fulfillment");
    Queue orders = quorumQueue("orders");
    Queue deadlines = quorumQueue("deadlines");

    List<Declarable> declarations = new ArrayList<>();
    declarations.add(business);
    declarations.add(deadline);
    declarations.add(feed);
    declarations.add(relations);
    declarations.add(media);
    declarations.add(cache);
    declarations.add(activities);
    declarations.add(fulfillment);
    declarations.add(orders);
    declarations.add(deadlines);
    declarations.add(BindingBuilder.bind(feed).to(business).with("FEED"));
    declarations.add(BindingBuilder.bind(relations).to(business).with("LIKE"));
    declarations.add(BindingBuilder.bind(relations).to(business).with("FOLLOW"));
    declarations.add(BindingBuilder.bind(media).to(business).with("MEDIA_DELETE"));
    declarations.add(BindingBuilder.bind(cache).to(business).with("SHOP_INVALIDATE"));
    declarations.add(BindingBuilder.bind(activities).to(business).with("SECKILL_PUBLISH"));
    declarations.add(BindingBuilder.bind(activities).to(business).with("SECKILL_RETRY"));
    declarations.add(BindingBuilder.bind(fulfillment).to(business).with("SECKILL_FULFILL"));
    declarations.add(BindingBuilder.bind(orders).to(business).with("ORDER_CREATED"));
    declarations.add(BindingBuilder.bind(orders).to(business).with("ORDER_PAID"));
    declarations.add(BindingBuilder.bind(orders).to(business).with("ORDER_CLOSED"));
    declarations.add(BindingBuilder.bind(deadlines).to(deadline).with("ORDER_EXPIRE"));
    return new Declarables(declarations);
  }

  private Queue quorumQueue(String suffix) {
    return QueueBuilder.durable(queuePrefix + "." + suffix)
        .withArgument("x-queue-type", "quorum")
        .withArgument("x-delayed-retry-type", "failed")
        .withArgument("x-delayed-retry-min", 1000L)
        .withArgument("x-delayed-retry-max", 30000L)
        .build();
  }
}
