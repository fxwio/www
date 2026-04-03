---
title: "我的 LLM Gateway 怎么做到上游挂了用户无感的"
description: "多供应商故障转移 + 熔断 + 健康检查联动实战"
pubDatetime: 2025-11-21T09:42:00+08:00
author: Fuxiang Wang
tags:
  - llm-gateway
  - fault-tolerance
  - go
draft: false
hideEditPost: true
timezone: Asia/Shanghai
---

> 多供应商故障转移 + 熔断 + 健康检查联动实战

## 问题是什么

做 AI 应用的人都遇到过这种事：你调 OpenAI 的接口，突然返回 500 了，或者 Anthropic 那边限流了给你 429。如果你的系统只对接一个供应商，那用户直接看到一个报错页面——体验崩了。

我在做 [Strait](https://github.com/fxwio/strait)（一个 LLM 推理网关）的时候，核心目标就一个：**上游供应商出问题，用户不应该感知到**。

怎么做到？两层容错 + 双模健康检查。

## 两层容错引擎

先看整体架构：

![两层容错引擎架构图](/diagrams/blog-01-fault-tolerance-arch.svg)

一个请求进来之后，网关做两件事：

**内层：同供应商重试（Retry）**

- 5xx、网络超时这类临时性故障 → 在同一个供应商上重试
- 带退避（backoff），默认 200ms，避免雪崩
- 重试次数可配置，per-provider 粒度

**外层：跨供应商故障转移（Failover）**

- 401/403/404/429 这些 4xx → 说明这个供应商有结构性问题（key 失效、模型下线、限流），重试没意义，直接切下一个供应商
- 内层重试耗尽了也会 failover

核心决策在 `classifyUpstreamAttempt` 函数里，逻辑很清晰：

```go
// strait/internal/proxy/proxy.go

func classifyUpstreamAttempt(r *http.Request, resp *http.Response, err error) upstreamAttemptDecision {
    reason := upstreamFailureReason(r, resp, err)

    // 客户端主动断开 → 直接终止，不浪费资源
    if isClientCanceledRequest(r, err) {
        return upstreamAttemptDecision{Action: upstreamAttemptTerminateRequest, Reason: reason}
    }
    // 网络错误/超时 → 在同一供应商重试
    if err != nil {
        return upstreamAttemptDecision{Action: upstreamAttemptRetrySameProvider, Reason: reason}
    }
    // 401/403/404/429 → 结构性问题，切换供应商
    if shouldFailoverStatusCode(resp.StatusCode) {
        return upstreamAttemptDecision{Action: upstreamAttemptFailoverNextProvider, Reason: reason}
    }
    // 5xx → 临时问题，在同一供应商重试
    if isRetryableStatusCode(resp.StatusCode) {
        return upstreamAttemptDecision{Action: upstreamAttemptRetrySameProvider, Reason: reason}
    }
    // 正常响应 → 返回给客户端
    return upstreamAttemptDecision{Action: upstreamAttemptReturn, Reason: reason}
}
```

为什么 4xx 要 failover 而不是 retry？举个例子：OpenAI 返回 429 (Too Many Requests)，在同一个 key 上重试只会继续被限流。切到 Anthropic（或者另一个 OpenAI key），立刻就能正常响应。

## 请求流转的完整路径

看代码里的主循环更直观。外层遍历候选供应商，内层跑重试：

```go
// strait/internal/proxy/proxy.go - ServeHTTP 核心循环（简化）

for providerIndex, provider := range gatewayCtx.CandidateProviders {
    attemptBudget := effectiveRetryCount(provider) + 1

    for attempt := 1; attempt <= attemptBudget; attempt++ {
        resp, err := h.client.Do(upstreamReq)
        decision := classifyUpstreamAttempt(r, resp, err)

        switch decision.Action {
        case upstreamAttemptRetrySameProvider:
            // 等退避时间后继续 attemptLoop
            waitRetryBackoff(r.Context(), backoff)
            continue

        case upstreamAttemptFailoverNextProvider:
            // 跳出 attemptLoop，进入下一个 provider
            break attemptLoop

        case upstreamAttemptReturn:
            // 成功！写响应头标记走了哪个供应商
            w.Header().Set("X-Gateway-Upstream-Provider", provider.Name)
            w.Header().Set("X-Gateway-Upstream-Retries", strconv.Itoa(totalRetries))
            return

        case upstreamAttemptTerminateRequest:
            // 客户端自己断了，不用管了
            return
        }
    }
    // 当前 provider 耗尽 → failover 到下一个
    gatewayCtx.FailoverCount++
}
```

注意响应头里会带上 `X-Gateway-Upstream-Provider` 和 `X-Gateway-Upstream-Retries`，调用方可以知道最终走的哪条路。这对排查问题很有帮助。

## 主动 + 被动双模健康检查

光靠请求时的 failover 还不够——如果一个供应商已经宕了 10 分钟，每次请求还是先发给它再超时切换，延迟白白增加。

所以我做了两种健康检查：

![健康检查联动状态机](/diagrams/blog-01-health-check-fsm.svg)

**被动健康检查（Passive Probe）**

每次真实请求的响应都会经过 `markPassiveProbeResult`，更新这个供应商的健康状态。不需要额外的网络开销。

```go
// 每次上游请求完成后都会调用
markPassiveProbeResult(provider.Name, provider.BaseURL, resp, err)
```

**主动健康检查（Active Probe）**

后台 goroutine 按配置的间隔（默认 15s）向每个供应商发探测请求。探测逻辑很有意思——如果供应商配了模型，会发一个最小 token 的 chat 请求做真实探测；否则退化为 GET 请求：

```go
// strait/internal/proxy/health.go

func probeProvider(client *http.Client, provider config.ProviderConfig) {
    // 优先发真实 API 请求探测（最小 token）
    if len(provider.Models) > 0 {
        adapterProvider := adapter.GetProvider(provider.Name)
        req, err = adapterProvider.GenerateProbeRequest(targetURL, provider.APIKey, provider.Models[0])
    }
    // 降级为 GET 探测
    if req == nil {
        req, _ = http.NewRequestWithContext(ctx, http.MethodGet, probeURL, nil)
    }
}
```

**和 gobreaker 熔断器的联动**

健康检查结果还会和 circuit breaker 联动。路由选择供应商时会检查两个维度：

```go
func resolveProviderHealth(candidate model.ProviderRoute) (known bool, healthy bool) {
    // 先查熔断器状态——如果熔断器 Open，直接判定不健康
    breakerKnown, breakerHealthy := resolveCircuitBreakerHealth(candidate)
    if breakerKnown && !breakerHealthy {
        return true, false
    }
    // 再查主动/被动探测结果
    status, ok := providerHealthMap[candidate.Name]
    return ok, status.Healthy
}
```

这样一来，不健康的供应商在路由阶段就被跳过了，不会浪费一次超时等待。

## 实际效果

| 场景            | 无容错              | 有容错                                 |
| --------------- | ------------------- | -------------------------------------- |
| 供应商 5xx      | 用户看到错误        | 200ms 退避后自动重试，通常第 2 次就过  |
| 供应商 key 失效 | 所有请求失败        | 即时切换到下一个供应商                 |
| 供应商宕机 5min | 每个请求等 30s 超时 | 15s 内被主动探测标记，后续请求直接跳过 |

整个过程对用户来说就是"响应慢了零点几秒"，而不是"你的服务挂了"。

## 写在最后

容错这个东西，核心就是**把决策分层**。不要用一个大 try-catch 兜住所有问题。网络抖了和 key 失效是完全不同的故障模式，应该用不同的策略来处理。

分层之后，每一层的逻辑都很简单——简单到一眼能看懂，简单到不容易出 bug。这就是我做 Strait 的设计哲学。
