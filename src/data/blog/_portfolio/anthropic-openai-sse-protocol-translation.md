---
title: "Anthropic 的 SSE 和 OpenAI 的不一样——我是怎么做实时协议转换的"
description: "把 Anthropic 的流式事件翻译成 OpenAI 格式，零拷贝，逐 chunk 转发"
pubDatetime: 2025-11-28T21:37:00+08:00
author: Fuxiang Wang
tags:
  - llm-gateway
  - sse
  - streaming
draft: false
hideEditPost: true
timezone: Asia/Shanghai
---

> 把 Anthropic 的流式事件翻译成 OpenAI 格式，零拷贝，逐 chunk 转发

## 问题是什么

做 LLM 网关有个绕不过去的坑：**不同供应商的流式协议不兼容**。

OpenAI 和 Anthropic 都用 SSE（Server-Sent Events），但事件格式完全不同：

- **OpenAI**：每个 chunk 是一个完整的 `chat.completion.chunk` JSON
- **Anthropic**：事件是分阶段的——`message_start`、`content_block_start`、`content_block_delta`、`message_delta`，每种有不同的 payload 结构

如果你的网关对外暴露 OpenAI 兼容接口，就必须把 Anthropic 的流式事件**实时翻译**成 OpenAI 格式，同时保持流式体验——不能等全部事件收完再转换。

## 有状态的事件转换

![SSE 协议转换架构](/diagrams/blog-04-sse-translation.svg)

核心挑战：Anthropic 的信息是**分散在多个事件里**的。`message_start` 里有 model 和 id，`content_block_delta` 里有文本内容，`message_delta` 里有 stop_reason。而 OpenAI 的每个 chunk 都需要 id、model、content 这些字段。

所以转换器必须是**有状态的**——用一个 state 对象记住之前事件里的信息：

```go
// strait/internal/adapter/stream_translator.go

type anthropicStreamState struct {
    w        http.ResponseWriter
    flusher  http.Flusher
    canFlush bool
    created  int64
    msgID    string    // 从 message_start 拿到，后续 chunk 复用
    model    string    // 从 message_start 拿到
    chunkBuf []byte    // 复用的输出缓冲区
    deltaBuf []byte    // 复用的 delta JSON 缓冲区
}
```

`chunkBuf` 和 `deltaBuf` 是两个**可复用的 byte slice**。每次写 chunk 不会重新分配内存，而是在已有 slice 上 `append`（从 `[:0]` 开始）。这是零分配的关键。

## 事件分发：5 种事件，5 种处理

Anthropic 的 SSE 有 5 种核心事件类型，每种的处理逻辑不同：

```go
// strait/internal/adapter/stream_translator.go

func dispatchAnthropicEvent(evType string, data []byte, state *anthropicStreamState) error {
    switch evType {
    case "message_start":
        // 提取 id 和 model，写第一个 chunk（role: assistant）
        state.msgID = payload.Message.ID
        state.model = payload.Message.Model
        return state.writeChunk(assistantRoleDelta, nil)

    case "content_block_start":
        // tool_use 类型需要发 tool call header
        if payload.ContentBlock.Type == "tool_use" {
            return state.writeChunk(state.toolHeaderDelta(...), nil)
        }

    case "content_block_delta":
        // 文本增量 → textDelta
        // JSON 参数增量 → toolArgumentDelta
        switch payload.Delta.Type {
        case "text_delta":
            return state.writeChunk(state.textDelta(payload.Delta.Text), nil)
        case "input_json_delta":
            return state.writeChunk(state.toolArgumentDelta(...), nil)
        }

    case "message_delta":
        // 结束信号，带 finish_reason
        finishReason := stopReasonToFinishReason(payload.Delta.StopReason)
        return state.writeChunk([]byte(`{}`), &finishReason)
    }
    return nil
}
```

## 零分配的 JSON 构建

每个 chunk 的 JSON 不是用 `json.Marshal` 生成的，而是手写拼接的。为什么？因为流式场景下**每个文本 delta 都会触发一次 JSON 构建**，如果用反射的 `json.Marshal`，每秒可能有上百次分配。

```go
func (s *anthropicStreamState) writeChunk(deltaJSON []byte, finishReason *string) error {
    buf := s.chunkBuf[:0]  // 复用已有 slice，零分配
    buf = append(buf, "data: {"...)
    buf = appendJSONStringField(buf, "id", s.msgID)
    buf = append(buf, ',')
    buf = appendJSONConstStringField(buf, "object", "chat.completion.chunk")
    buf = append(buf, ',')
    buf = appendJSONIntField(buf, "created", s.created)
    buf = append(buf, ',')
    buf = appendJSONStringField(buf, "model", s.model)
    buf = append(buf, `,"choices":[{"index":0,"delta":`...)
    buf = append(buf, deltaJSON...)
    // ...
    buf = append(buf, "}]}\n\n"...)

    s.chunkBuf = buf  // 保存增长后的 slice 供下次复用
    _, err := s.w.Write(buf)
    // 立即 flush，保证客户端实时收到
    if s.canFlush {
        s.flusher.Flush()
    }
    return err
}
```

这里有个 Go 的技巧：`s.chunkBuf[:0]` 不释放底层数组，只是把长度重置为 0。下一次 `append` 会在同一块内存上写入，只有在 chunk 变大时才会触发一次扩容。实际运行中，前几个 chunk 之后缓冲区就稳定了，后续全是零分配。

## SSE 行解析

SSE 协议本身也需要解析——逐行读取，遇到空行时分发事件：

```go
for {
    line, err := readSSELine(reader, lineBuf[:0])
    lineBuf = line  // 复用 line buffer

    if len(line) == 0 {
        // 空行 = 事件边界
        if currentEvent.hasData() {
            dispatchAnthropicSSEEvent(&currentEvent, &state)
        }
        currentEvent.reset()  // reset 也是 [:0]，不分配
    } else {
        currentEvent.consume(line)  // 解析 event: 和 data: 前缀
    }
}
```

`readSSELine` 也做了 buffer 复用：

```go
func readSSELine(reader *bufio.Reader, dst []byte) ([]byte, error) {
    dst = dst[:0]
    for {
        chunk, err := reader.ReadSlice('\n')
        dst = append(dst, chunk...)
        switch err {
        case nil:
            return bytes.TrimRight(dst, "\r\n"), nil
        case bufio.ErrBufferFull:
            continue  // 行太长，继续读
        // ...
        }
    }
}
```

## 效果

协议转换通路（Anthropic → OpenAI SSE）的性能：

| 指标              | 数值     |
| ----------------- | -------- |
| 转换通路吞吐      | ~16K QPS |
| 协议转换 p99 延迟 | < 41μs   |

41 微秒完成一次完整的协议转换 + JSON 构建 + flush，核心就是**状态机 + buffer 复用 + 手写 JSON**。

## 写在最后

流式协议转换的关键不是算法复杂度，而是**分配策略**。在热路径上每减少一次内存分配，就少一次 GC 压力。`[:0]` 重用 slice 是 Go 里最简单也最有效的优化手段之一。
