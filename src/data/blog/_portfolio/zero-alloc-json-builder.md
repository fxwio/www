---
title: "encoding/json 太慢了，我手写了一个零分配 JSON 构建器"
description: "在协议转换热路径上，为什么我不用标准库，以及怎么做到零分配"
pubDatetime: 2025-10-31T22:03:00+08:00
author: Fuxiang Wang
tags:
  - go
  - performance
  - json
draft: false
hideEditPost: true
timezone: Asia/Shanghai
---

> 在协议转换热路径上，为什么我不用标准库，以及怎么做到零分配

## 背景

LLM Gateway 需要把 Anthropic 的响应格式转成 OpenAI 格式。非流式场景下，一个完整的 Anthropic 响应要转成一个完整的 OpenAI `chat.completion` JSON。

用标准库 `encoding/json` 做这件事最直觉：先 `json.Unmarshal` 解析 Anthropic 响应，映射成 OpenAI 的结构体，再 `json.Marshal` 输出。

问题是：这条路径每个请求都走，**每次 Marshal/Unmarshal 都会触发反射和内存分配**。在 ~19K QPS 的负载下，这些分配累积起来就是 GC 压力。

所以我手写了两套东西：一个零分配的 JSON **构建器**，一个零分配的 JSON **解析器**。

## 零分配 JSON 构建器

构建 OpenAI 响应 JSON 的方式是直接用 `[]byte` 拼接：

```go
// strait/internal/adapter/anthropic_response_fast.go

func translateAnthropicTextOnlyToOpenAI(data []byte) ([]byte, bool, error) {
    resp, ok, err := parseAnthropicTextOnlyResponse(data)
    if !ok || err != nil {
        return nil, ok, err
    }

    // 预估长度，一次分配到位
    out := make([]byte, 0, len(data)+128)
    out = append(out, `{"id":`...)
    out = strconv.AppendQuote(out, resp.ID)
    out = append(out, `,"object":"chat.completion","created":`...)
    out = strconv.AppendInt(out, created, 10)
    out = append(out, `,"model":`...)
    out = strconv.AppendQuote(out, resp.Model)
    out = append(out, `,"choices":[{"index":0,"message":{"role":"assistant","content":`...)
    out = strconv.AppendQuote(out, resp.Text)
    out = append(out, `},"finish_reason":`...)
    out = strconv.AppendQuote(out, finishReason)
    out = append(out, `}],"usage":{"prompt_tokens":`...)
    out = strconv.AppendInt(out, int64(resp.InputTokens), 10)
    // ...
    out = append(out, `}}`...)
    return out, true, nil
}
```

几个关键点：

1. **`make([]byte, 0, len(data)+128)`** — 一次预分配，后续 `append` 不触发扩容
2. **`strconv.AppendQuote`** — 直接往 `[]byte` 里追加带转义的 JSON 字符串，不返回新 `string`
3. **`strconv.AppendInt`** — 同理，整数直接追加
4. **常量字符串用 `append(buf, "literal"...)`** — 编译器内联，无分配

对比 `json.Marshal` 的路径：反射获取字段 → 构建 encoder → 分配临时 buffer → 编码 → 再分配输出 buffer。每一步都有分配。

## 零分配 JSON 解析器

解析 Anthropic 响应更有意思。标准库 `json.Unmarshal` 的问题：

1. 先分配 `interface{}` 的 map/slice 树
2. 用反射匹配 struct tag
3. 字符串都要从 `[]byte` 拷贝成 `string`

我的做法是**手写递归下降解析器**，直接在原始 `[]byte` 上扫描：

```go
// strait/internal/adapter/anthropic_response_fast.go

func parseAnthropicTextOnlyResponse(data []byte) (anthropicTextOnlyResponse, bool, error) {
    var resp anthropicTextOnlyResponse
    idx := skipAdapterJSONWhitespace(data, 0)

    for {
        // 直接扫描 key 字符串
        key, next, err := scanAdapterJSONString(data, idx)
        idx = next
        // 跳过冒号
        idx = skipAdapterJSONWhitespace(data, idx+1)

        switch key {
        case "id":
            resp.ID, idx, _ = scanAdapterJSONString(data, idx)
        case "model":
            resp.Model, idx, _ = scanAdapterJSONString(data, idx)
        case "content":
            // 解析 content 数组，拼接 text blocks
            resp.Text, idx, _ = parseAnthropicTextContentArray(data, idx)
        case "usage":
            // 直接解析嵌套对象里的 input/output tokens
            resp.InputTokens, resp.OutputTokens, idx = parseUsageObject(data, idx)
        default:
            // 不关心的字段 → 跳过整个 value（递归跳过嵌套对象）
            idx, _ = skipAdapterJSONValue(data, idx)
        }
    }
}
```

`scanAdapterJSONString` 直接在 `[]byte` 上找引号边界，处理转义序列：

```go
func scanAdapterJSONString(data []byte, idx int) (string, int, error) {
    // 跳过开头的引号
    idx++ // skip '"'
    start := idx

    for idx < len(data) {
        if data[idx] == '\\' {
            idx += 2  // 转义字符跳两个
            continue
        }
        if data[idx] == '"' {
            // 无转义的简单路径：直接零拷贝取子串
            return string(data[start:idx]), idx + 1, nil
        }
        idx++
    }
    return "", idx, errUnterminatedString
}
```

对于没有转义字符的字符串（绝大多数情况），`string(data[start:idx])` 不需要 Unquote，零额外处理。

`skipAdapterJSONValue` 能递归跳过任意 JSON 值——对象、数组、字符串、数字、布尔：

```go
func skipAdapterJSONValue(data []byte, idx int) (int, error) {
    switch data[idx] {
    case '"':
        _, next, err := scanAdapterJSONString(data, idx)
        return next, err
    case '{':
        return skipAdapterJSONObject(data, idx)
    case '[':
        return skipAdapterJSONArray(data, idx)
    default:
        // 数字、true、false、null → 扫到分隔符为止
        for idx < len(data) && !isJSONDelimiter(data[idx]) {
            idx++
        }
        return idx, nil
    }
}
```

![零分配 JSON 处理流程](/diagrams/blog-05-zero-alloc-json.svg)

## 为什么不用 jsoniter 或 easyjson

1. **jsoniter**：虽然比标准库快 5-10 倍，但仍然有反射开销，且多了一个依赖
2. **easyjson**：需要代码生成，增加构建复杂度，且生成的代码不如手写灵活
3. **手写**：这个场景的 JSON 结构是**固定的**（Anthropic 和 OpenAI 的格式不会频繁变），手写的 ROI 很高——代码量不大，性能最优

关键判断：**如果 JSON 结构是动态的或经常变，用标准库 / jsoniter**。如果结构固定且在热路径上，手写更合适。

## 优雅降级

手写解析器有个风险：如果 Anthropic 改了响应格式，手写的解析器可能 panic 或返回错误结果。

所以我做了**双路降级**：

```go
func translateAnthropicTextOnlyToOpenAI(data []byte) ([]byte, bool, error) {
    // 快速检查：包含 tool_use 或 error → 不走快速路径
    if bytes.Contains(data, []byte(`"tool_use"`)) || bytes.Contains(data, []byte(`"error"`)) {
        return nil, false, nil  // 返回 false，让调用方走标准 json.Unmarshal
    }
    // ...
}
```

返回 `(nil, false, nil)` 而不是 error，调用方收到 `ok=false` 后会 fallback 到标准的 `json.Unmarshal` + struct mapping 路径。手写解析器只处理最常见的 text-only 场景（占 80%+ 的请求），复杂场景（tool call、error）走标准路径。

## 写在最后

性能优化不是"用不用标准库"的二选一。正确的做法是：**热路径用手写，冷路径用标准库，Grace Degradation 连接两者**。

这样既拿到了性能，也保住了正确性。
