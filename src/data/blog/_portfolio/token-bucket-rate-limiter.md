---
title: "给 API 网关做限流——令牌桶 + TTL 自动回收实战"
description: "每个 token 一个桶，不活跃的桶自动回收，不让内存泄漏"
pubDatetime: 2025-11-07T20:26:00+08:00
author: Fuxiang Wang
tags:
  - api-gateway
  - rate-limiting
  - go
draft: false
hideEditPost: true
timezone: Asia/Shanghai
---

> 每个 token 一个桶，不活跃的桶自动回收，不让内存泄漏

## 为什么要限流

LLM API 很贵。如果不做限流，一个用户写个死循环就能把你这个月的账单刷爆。

但限流不是简单地"全局 100 QPS"就完事了。在多租户场景下，你需要：

1. **per-token 限流**：每个 API token 有独立的 QPS 配额
2. **per-IP 限流**：未认证的请求按 IP 限流
3. **动态 burst**：允许瞬时突发，但长期不超额
4. **不泄漏内存**：用户的 token 可能成千上万，不活跃的桶要自动清理

## 整体设计

![令牌桶限流架构](/diagrams/blog-06-rate-limiter.svg)

两层身份识别 + 一个带 TTL 的限流器：

```go
// strait/internal/middleware/ratelimit.go

func buildRateLimitIdentity(r *http.Request) (scope string, key string) {
    if authCtx, ok := GetClientAuthContext(r); ok && authCtx.Token != "" {
        // 已认证 → 用 token 指纹做 key（不存原始 token）
        return "token", "rate_limit:token:" + authCtx.Fingerprint
    }
    // 未认证 → 用客户端 IP 做 key
    clientIP := extractClientIP(r)
    return "ip", "rate_limit:ip:" + clientIP
}
```

注意 key 用的是 token 的 **SHA256 指纹**，不是原始 token。这样即使限流器的内存被 dump，也不会泄露用户的 API key。

## 令牌桶实现

核心是一个带 key 的本地令牌桶。每个 key 对应一个独立的桶：

```go
// strait/internal/middleware/local_limiter.go

type localTokenBucket struct {
    mu       sync.Mutex
    rate     float64    // 每秒恢复多少 token
    burst    float64    // 桶的容量上限
    tokens   float64    // 当前可用 token 数
    last     time.Time  // 上次操作时间
    lastSeen atomic.Int64  // 最后活跃时间（用于 TTL）
}
```

`Allow` 方法实现令牌桶算法——**不是用定时器补充 token，而是在每次调用时按时间差计算**：

```go
func (b *localTokenBucket) Allow(rate float64, burst int, now time.Time) bool {
    b.mu.Lock()
    defer b.mu.Unlock()

    // 动态更新 rate 和 burst（per-token 配置可能变）
    if rate > 0 { b.rate = rate }
    if burst > 0 {
        newBurst := float64(burst)
        if newBurst > b.burst {
            b.tokens = newBurst  // burst 增大 → 立即充满
        }
        b.burst = newBurst
    }

    // 按时间差补充 token
    elapsed := now.Sub(b.last).Seconds()
    b.last = now
    b.tokens += elapsed * b.rate
    if b.tokens > b.burst {
        b.tokens = b.burst
    }

    // 尝试消耗 1 个 token
    if b.tokens < 1 {
        return false
    }
    b.tokens -= 1
    return true
}
```

这种"惰性补充"比起用 goroutine + ticker 的方式更省资源——不活跃的桶完全不消耗 CPU。

## 动态 Burst 的处理

用户的 per-token 配置可能在运行时变化。有个细节值得注意：

```go
if newBurst > b.burst {
    b.tokens = newBurst  // burst 增大 → 立即充满
}
b.burst = newBurst
if b.tokens > b.burst {
    b.tokens = b.burst   // burst 减小 → 截断
}
```

- **burst 增大**：立即把 tokens 充到新的上限。这样用户不用等限流恢复
- **burst 减小**：截断到新上限。不会出现"tokens 比 burst 还大"的异常状态

## TTL 自动回收

重点来了——如果你有 10 万个 token，每个 token 创建一个桶，但大部分 token 一天就用一次。不清理的话内存会持续增长。

我的方案：**每 1024 次调用触发一次清理**：

```go
const (
    localLimiterBucketTTL       = 10 * time.Minute
    localLimiterCleanupInterval = 1024
)

func (l *keyedLocalLimiter) maybeCleanup(now time.Time) {
    // 每 1024 次调用才检查一次
    if l.calls.Add(1) % localLimiterCleanupInterval != 0 {
        return
    }

    cutoff := now.Add(-localLimiterBucketTTL).UnixNano()

    l.mu.Lock()
    defer l.mu.Unlock()
    for key, bucket := range l.buckets {
        if bucket.lastSeen.Load() < cutoff {
            delete(l.buckets, key)  // 10 分钟没活跃 → 回收
        }
    }
}
```

为什么是 1024 而不是每次都检查？因为 `range` 遍历 map + `delete` 有开销。1024 是个经验值——在高 QPS 下大约每秒清理一次，低 QPS 下间隔更长。

`lastSeen` 用的是 `atomic.Int64`，读写不需要加桶的 mutex。这样清理逻辑只需要加限流器的全局锁，不会和桶的 Allow 操作竞争。

## 限流响应头

限流不只是"拒不拒"的问题，还要告诉调用方限流状态：

```go
w.Header().Set("X-RateLimit-Limit", strconv.Itoa(qps))
w.Header().Set("X-RateLimit-Burst", strconv.Itoa(burst))
w.Header().Set("X-RateLimit-Scope", scope)  // "token" 或 "ip"
if !allowed {
    w.Header().Set("Retry-After", "1")
    response.WriteRateLimitError(w, "Rate limit exceeded.", "rate_limit_exceeded")
    return
}
```

调用方看到 `Retry-After: 1` 就知道 1 秒后重试。`X-RateLimit-Scope` 告诉调用方当前是按 token 还是按 IP 限流的——如果是 IP 限流，说明认证信息可能有问题。

## 写在最后

令牌桶算法本身不复杂，但工程实现中有三个容易忽略的点：

1. **惰性补充**优于 timer 补充——省 goroutine，不活跃的桶零开销
2. **TTL 清理**必须做——否则就是一个缓慢的内存泄漏
3. **key 安全**——限流 key 用指纹，不存原始 token
