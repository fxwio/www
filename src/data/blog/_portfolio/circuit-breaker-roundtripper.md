---
title: "把熔断器塞进 http.RoundTripper——Go 里最优雅的做法"
description: "不改业务代码，在 Transport 层透明实现 per-provider 熔断"
pubDatetime: 2025-11-14T23:08:00+08:00
author: Fuxiang Wang
tags:
  - llm-gateway
  - circuit-breaker
  - go
draft: false
hideEditPost: true
timezone: Asia/Shanghai
---

> 不改业务代码，在 Transport 层透明实现 per-provider 熔断

## 问题

LLM 供应商的 API 偶尔会出问题——连续 500、超时、限流。如果不做熔断，你的网关会一直把请求发给一个已经挂了的供应商，白白浪费时间和钱。

熔断器的思路很简单：失败率超过阈值 → 断开 → 不再发请求 → 定期试探 → 恢复了再接上。

但问题是：**怎么在不改业务代码的情况下加上熔断？**

## 答案：包装 http.RoundTripper

Go 的 `http.Client` 有个很好的设计：所有请求都走 `Transport.RoundTrip(req) (*Response, error)`。你可以包装这个接口，在 Transport 层透明地加上熔断：

```go
// strait/internal/proxy/transport.go

type CircuitBreakerTransport struct {
    Transport http.RoundTripper
}

func (c *CircuitBreakerTransport) RoundTrip(req *http.Request) (*http.Response, error) {
    breakerKey := breakerKeyForRequest(req)
    cb := getBreaker(breakerKey)

    respInterface, err := cb.Execute(func() (interface{}, error) {
        resp, err := c.Transport.RoundTrip(req)
        if err != nil {
            return nil, err
        }
        // 5xx 和 429 视为失败，触发熔断计数
        if resp.StatusCode >= 500 || resp.StatusCode == http.StatusTooManyRequests {
            return resp, fmt.Errorf("upstream error: status %d", resp.StatusCode)
        }
        return resp, nil
    })

    if err != nil {
        // 熔断器 Open 时会直接返回 error，不发请求
        if resp, ok := respInterface.(*http.Response); ok && resp != nil {
            return resp, nil  // 但如果有 response body，还是返回给上层
        }
        return nil, err
    }
    return respInterface.(*http.Response), nil
}
```

![熔断器 Transport 架构](/diagrams/blog-07-circuit-breaker.svg)

使用方式就一行——把 `CircuitBreakerTransport` 套在原始 Transport 外面：

```go
sharedTransport := &http.Transport{...}
transport := &CircuitBreakerTransport{Transport: sharedTransport}
client := &http.Client{Transport: transport}
```

业务代码还是 `client.Do(req)`，完全无感。

## per-provider 粒度的熔断

一个网关对接多个供应商（OpenAI、Anthropic、SiliconFlow）。OpenAI 挂了不能把 Anthropic 也熔断掉。

所以熔断器的 key 是 `provider_name@host`：

```go
func breakerKeyForRequest(req *http.Request) string {
    breakerKey := req.URL.Host
    if gatewayCtx, err := getGatewayContext(req); err == nil {
        breakerKey = gatewayCtx.TargetProvider + "@" + req.URL.Host
    }
    return breakerKey
}
// 例如: "openai@api.openai.com", "anthropic@api.anthropic.com"
```

每个 key 一个独立的 `gobreaker.CircuitBreaker` 实例，互不干扰。

## 熔断器状态机

用的是 [sony/gobreaker](https://github.com/sony/gobreaker)，三个状态：

- **Closed**（闭合）：正常放行请求，统计失败率
- **Open**（断开）：拒绝所有请求，等待超时
- **Half-Open**（半开）：放行少量探测请求，成功就恢复，失败继续断开

触发条件是可配置的：

```go
settings := gobreaker.Settings{
    Name:        key,
    MaxRequests: maxHalfOpenRequests,  // 半开状态放行几个请求
    Interval:    interval,             // 统计窗口（默认 10s）
    Timeout:     timeout,              // Open → Half-Open 等多久（默认 15s）
    ReadyToTrip: func(counts gobreaker.Counts) bool {
        // 最少 N 个请求才判断，避免样本太少误触发
        if counts.Requests < minimumRequests {
            return false
        }
        // 失败率超过阈值 → 触发熔断
        failureRatio := float64(counts.TotalFailures) / float64(counts.Requests)
        return failureRatio >= failureRatioThreshold
    },
    OnStateChange: func(name string, from, to gobreaker.State) {
        // 状态变化 → 更新 Prometheus + 打日志
        setCircuitBreakerMetric(name, to)
        logger.Log.Warn("Circuit breaker state changed",
            "breaker", name, "from", from, "to", to)
    },
}
```

`minimumRequests` 很关键——如果去掉这个条件，一个供应商刚启动时第一个请求就失败了，失败率 100%，直接触发熔断。设最低请求数就是为了避免这种误判。

## 和健康检查的联动

熔断器的状态会被健康检查系统读取，用于路由决策：

```go
func resolveCircuitBreakerHealth(provider model.ProviderRoute) (known bool, healthy bool) {
    known, state := circuitBreakerStateForProvider(provider)
    if !known {
        return false, true  // 没有熔断记录 → 默认健康
    }
    return true, state != gobreaker.StateOpen  // Open → 不健康
}
```

这意味着熔断器 Open 的供应商会在**路由阶段就被跳过**，不会进入 failover 循环。和博客 1 里讲的两层容错引擎串联起来，形成完整的故障隔离链路。

## 一个细节：5xx 返回 response 但也要计失败

注意 `RoundTrip` 里的这段：

```go
if resp.StatusCode >= 500 {
    return resp, fmt.Errorf("upstream error: status %d", resp.StatusCode)
}
```

同时返回了 `resp` 和 `error`。这是 gobreaker 的 `Execute` 约定：返回 error 表示"这次算失败"，但 response body 可能有有用信息（比如错误详情），上层还是需要它。

所以外面有个兜底：

```go
if resp, ok := respInterface.(*http.Response); ok && resp != nil {
    return resp, nil  // 有 body 就返回，让上层处理
}
```

## 写在最后

`http.RoundTripper` 是 Go HTTP 体系里最强大的扩展点。熔断、限流、Tracing、日志——都可以通过包装 Transport 来实现，业务代码零侵入。

这种"装饰器模式"在 Go 里用接口实现特别自然。一个 `RoundTrip` 方法，就能串起整个中间件链。
