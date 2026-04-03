---
title: "用 Redis 给 AGV 做电池调度——ZSet + 分布式锁 + 状态机"
description: "怎么用最简单的技术栈解决仓储场景的调度问题"
pubDatetime: 2025-10-24T21:14:00+08:00
author: Fuxiang Wang
tags:
  - redis
  - scheduling
  - system-design
draft: false
hideEditPost: true
timezone: Asia/Shanghai
---

> 怎么用最简单的技术栈解决仓储场景的调度问题

## 业务背景

在自动驾驶重卡的仓储系统里，AGV（自动搬运车）需要频繁更换电池。一个电池仓里有几十块不同类型的电池，多台 AGV 同时请求换电。

调度引擎需要解决三个问题：

1. **选哪块电池**：不同 AGV 需要不同类型的电池，同类型里选电量最高的
2. **不能重复分配**：两台 AGV 不能拿到同一块电池
3. **异常恢复**：如果 AGV 在搬运过程中故障，电池要能回到可分配池

## 为什么用 Redis 而不是数据库

电池调度是高频操作（秒级），对延迟敏感。用 MySQL 的话：

- 悲观锁 `SELECT FOR UPDATE`：持锁时间长，并发高时死锁
- 乐观锁 version：冲突重试多，不确定性高
- 专门建调度表：schema 复杂，查询慢

Redis 的好处：

- 单线程模型，天然无并发问题（在单命令层面）
- ZSet 带分数排序，天然适合按优先级选择
- SetNX 做分布式锁，语义简单

## 核心设计

![AGV 电池调度架构](/diagrams/blog-10-agv-scheduling.svg)

### ZSet 优先级队列

每种电池类型一个 ZSet，score 是电量百分比：

```
battery:type:A → ZSet
  member: "BAT-001"  score: 95.5  (95.5% 电量)
  member: "BAT-002"  score: 87.2
  member: "BAT-003"  score: 72.1

battery:type:B → ZSet
  member: "BAT-101"  score: 98.0
  member: "BAT-102"  score: 45.3
```

选电池时用 `ZREVRANGEBYSCORE`（按 score 降序），拿到电量最高的那块：

```go
// 伪代码
candidates := redis.ZRevRangeByScore(ctx, "battery:type:A", &redis.ZRangeBy{
    Min: "60",   // 最低电量要求 60%
    Max: "+inf",
    Count: 1,    // 只取 1 块
})
```

### 分布式锁防止重复分配

拿到候选电池后，要用 SetNX 加锁，防止另一台 AGV 同时分配到同一块电池：

```go
lockKey := "lock:battery:" + batteryID
acquired := redis.SetNX(ctx, lockKey, agvID, 5*time.Minute)
if !acquired {
    // 被别人抢了，重新选下一块
    continue
}

// 加锁成功 → 从 ZSet 移除（不再可分配）
redis.ZRem(ctx, "battery:type:A", batteryID)
```

锁有 5 分钟 TTL——如果 AGV 在搬运过程中宕机，锁会自动释放。配合下面的状态机，电池会回到可分配池。

### 回调驱动状态机

电池在几个状态之间流转：

```
Available → Allocated → InTransit → InUse → Charging → Available
                ↓           ↓
              Timeout     Failure
                ↓           ↓
              Available   Available（回收）
```

AGV 通过回调接口上报状态变化：

```go
func handleBatteryCallback(batteryID string, event string) {
    switch event {
    case "pickup_complete":
        // AGV 已取走电池
        setState(batteryID, "in_transit")

    case "install_complete":
        // 电池已装上 AGV
        setState(batteryID, "in_use")
        releaseLock(batteryID)  // 释放分布式锁

    case "return":
        // 电池退回（低电量/故障）
        setState(batteryID, "charging")
        // 充电完成后定时任务会把它加回 ZSet

    case "timeout":
        // AGV 搬运超时 → 回收电池
        setState(batteryID, "available")
        redis.ZAdd(ctx, "battery:type:"+batteryType, &redis.Z{
            Score:  currentCharge,
            Member: batteryID,
        })
        releaseLock(batteryID)
    }
}
```

超时检测用 Redis 的 key 过期事件或者定时扫描实现。

### 多电池类型差异化策略

不同电池类型有不同的选择策略：

```go
type BatteryStrategy interface {
    SelectBattery(ctx context.Context, agvID string) (string, error)
    MinCharge() float64  // 最低电量
    Priority() string    // "charge" 按电量, "distance" 按距离
}
```

A 类型电池优先选电量最高的，B 类型可能优先选离 AGV 最近的。策略模式让不同类型的逻辑互不干扰。

## 为什么这个方案能提升 300% 效率

原来的调度是人工操作——工人看着电量表，手动分配电池，然后用对讲机通知 AGV。

自动调度之后：

- **选择速度**：从人工看表 2-3 分钟 → Redis 查询 <1ms
- **并发处理**：从一次处理一个 → 多台 AGV 同时调度
- **异常恢复**：从人工发现超时 → 自动回收，0 人工介入
- **充电策略**：永远选电量最高的，不会出现"人工偏好"导致某些电池过度使用

## 写在最后

这个方案的技术栈其实很简单——Redis ZSet + SetNX + 状态机。没有用 Kafka，没有用复杂的调度框架。

但正是因为简单，才容易理解、容易排查问题、容易扩展。仓储现场的运维人员看 Redis 的数据就能知道每块电池在什么状态，比起一个复杂的调度系统，这种透明度更实用。

技术选型的关键不是"用最先进的"，而是"用最会用的"。你对 Redis 足够熟悉，ZSet 就是最好的优先级队列。
