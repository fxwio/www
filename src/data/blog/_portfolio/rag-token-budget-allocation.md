---
title: "给 RAG 的 Prompt 装个预算——Token 动态分配怎么做"
description: "LLM 上下文窗口有限，检索结果、会话记忆、用户问题怎么分 token？"
pubDatetime: 2025-12-12T10:11:00+08:00
author: Fuxiang Wang
tags:
  - rag
  - prompt-engineering
  - tokens
draft: false
hideEditPost: true
timezone: Asia/Shanghai
---

> LLM 上下文窗口有限，检索结果、会话记忆、用户问题怎么分 token？

## 问题：塞多了截断，塞少了不准

RAG 系统的最后一步是把检索到的文档片段（chunks）和用户的问题一起喂给 LLM，让它基于这些上下文来回答。

听起来很简单，但有个实际问题：**LLM 的上下文窗口是有限的**。

- 塞太多 chunks → 超出上下文限制，要么被截断（回答不完整），要么 API 直接报错
- 塞太少 chunks → 上下文不够，LLM 胡编乱造
- 还有会话记忆（之前的对话）要塞进去，不然多轮对话时上下文断裂

所以需要一个 **Token 预算分配机制**：在有限的窗口里，动态决定每个部分占多少空间。

## 预算分配模型

我在 [Shoal](https://github.com/fxwio/shoal) 里设计的模型很直接——像做家庭预算一样，先扣刚性支出，剩下的给弹性支出。

![Token 预算分配瀑布图](/diagrams/blog-03-token-budget-waterfall.svg)

配置长这样：

```yaml
chat:
  input_max_tokens: 3000 # 总预算
  response_max_tokens: 512 # LLM 回答预留
  prompt_safety_tokens: 200 # 安全边际（防止 token 计数误差）
  context_max_tokens: 1800 # 上下文 chunks 上限
  memory_max_tokens: 600 # 会话记忆上限
  context_max_chunks: 4 # chunks 数量上限
  history_window_turns: 6 # 保留最近几轮对话
```

分配顺序：

```
总预算 (3000)
  - 响应预留 (512)        → 留给 LLM 生成回答
  - 安全边际 (200)        → 防止 token 计数近似误差导致溢出
  - 用户问题 (~50)        → 这轮的 query
  = 剩余可用 (~2238)
    → 上下文 chunks: min(剩余, 1800)
    → 会话记忆: min(剩余-已用, 600)
```

为什么要有安全边际？因为 token 计数是近似的（按字符数 / runesPerToken 估算），实际 tokenizer 的结果可能偏大。200 tokens 的缓冲能避免偶尔的溢出。

## 贪心装包：逐条塞 chunks

上下文 chunks 的分配用的是贪心策略——按检索相关性排序，从最相关的开始往里塞，塞不下就截断最后一条。

```go
// shoal/internal/service/chat/service.go

func (s *Service) selectContextHits(query string, hits []domain.SearchHit) []domain.SearchHit {
    // 可用预算 = 总预算 - 响应预留 - 安全边际 - query 本身
    available := s.cfg.Chat.InputMaxTokens -
                 s.cfg.Chat.ResponseMaxTokens -
                 s.cfg.Chat.PromptSafetyTokens -
                 s.approxTokens(query)
    if available <= 0 {
        return nil
    }

    // 上下文预算取较小值
    contextBudget := minInt(available, s.cfg.Chat.ContextMaxTokens)

    selected := make([]domain.SearchHit, 0, len(hits))
    used := 0

    for _, hit := range hits {
        hitTokens := s.approxTokens(hit.ChunkID) +
                     s.approxTokens(hit.Source) +
                     s.approxTokens(hit.Content)

        if hitTokens > contextBudget-used {
            // 塞不下完整的 chunk → 截断最后一条
            remaining := contextBudget - used
            if remaining <= 0 {
                break
            }
            truncated := truncateForTokens(hit.Content, remaining, s.cfg.Chat.RunesPerToken)
            if truncated == "" {
                break
            }
            hit.Content = truncated
        }

        selected = append(selected, hit)
        used += hitTokens
        if used >= contextBudget {
            break
        }
    }
    return selected
}
```

关键点：最后一条 chunk 如果放不下完整的，**不是直接扔掉，而是截断保留**。因为一段文档的前半部分通常也是有信息量的，扔掉太浪费了。

截断函数也很简单：

```go
func truncateForTokens(value string, maxTokens int, runesPerToken int) string {
    maxRunes := maxTokens * runesPerToken
    runes := []rune(value)
    if len(runes) <= maxRunes {
        return value
    }
    return string(runes[:maxRunes-1]) + "..."
}
```

注意用 `[]rune` 而不是字节切割，避免把中文字符劈成乱码。

## 记忆窗口：反向填充

会话记忆的分配更有意思——是从最新的对话往前回溯的。

![贪心装包 + 反向填充示意图](/diagrams/blog-03-packing-strategy.svg)

为什么要反向？因为最近的对话最重要。如果从前往后填，预算可能被早期的（不太相关的）对话占满了，最近的对话反而塞不进去。

```go
// shoal/internal/service/chat/service.go

func (s *Service) selectMemoryTurns(query string, turns []domain.ChatTurn, hits []domain.SearchHit) []domain.ChatTurn {
    // 可用预算：总预算 - 预留 - 安全边际 - query
    available := s.cfg.Chat.InputMaxTokens -
                 s.cfg.Chat.ResponseMaxTokens -
                 s.cfg.Chat.PromptSafetyTokens -
                 s.approxTokens(query)

    // 先扣掉已经选中的 chunks 占用的 token
    for _, hit := range hits {
        available -= s.approxTokens(hit.ChunkID) +
                     s.approxTokens(hit.Source) +
                     s.approxTokens(hit.Content)
    }
    if available <= 0 {
        return nil
    }

    memoryBudget := minInt(available, s.cfg.Chat.MemoryMaxTokens)

    selected := make([]domain.ChatTurn, 0, len(turns))
    used := 0

    // 关键：从后往前遍历（最新的对话优先）
    for idx := len(turns) - 1; idx >= 0; idx-- {
        turn := turns[idx]
        turnTokens := s.approxTokens(turn.Role) + s.approxTokens(turn.Content)
        if used+turnTokens > memoryBudget {
            break  // 预算用完，停止
        }
        selected = append(selected, turn)
        used += turnTokens
    }

    // 反转回正序（因为是倒着加的）
    for i, j := 0, len(selected)-1; i < j; i, j = i+1, j-1 {
        selected[i], selected[j] = selected[j], selected[i]
    }
    return selected
}
```

注意两个设计：

1. **记忆预算是在 chunks 之后计算的**——上下文优先级高于记忆。如果检索到的 chunks 特别多，记忆会被压缩甚至清空。这是故意的：RAG 的核心价值在于检索增强，记忆是锦上添花。

2. **反转操作**：因为是从后往前加入的，最终要 reverse 回正序，确保对话在 prompt 中按时间顺序排列。

## 整体调度

两个函数的调度由 `selectPromptInputs` 统一编排：

```go
func (s *Service) selectPromptInputs(query string, turns []domain.ChatTurn, hits []domain.SearchHit) ([]domain.ChatTurn, []domain.SearchHit) {
    // 先分配 chunks（优先级高）
    selectedHits := s.selectContextHits(query, trimHits(hits, s.cfg.Chat.ContextMaxChunks))
    // 再分配记忆（用 chunks 的剩余）
    selectedTurns := s.selectMemoryTurns(query, trimTurns(turns, s.cfg.Chat.HistoryWindowTurns), selectedHits)
    return selectedTurns, selectedHits
}
```

先 chunks 后 memory，优先级清晰。`trimHits` 和 `trimTurns` 先做数量上的粗筛（最多 4 个 chunks、最近 6 轮对话），再在 token 级别做精细分配。两层过滤，既高效又精确。

## 为什么不用精确 tokenizer

你可能注意到了，token 计算用的是字符数近似：

```go
func (s *Service) approxTokens(value string) int {
    runesPerToken := s.cfg.Chat.RunesPerToken  // 默认 2
    runes := utf8.RuneCountInString(value)
    return (runes + runesPerToken - 1) / runesPerToken
}
```

为什么不用 tiktoken 这类精确 tokenizer？

1. **性能**：精确 tokenizer 比字符计数慢 100 倍以上，在热路径上不值得
2. **够用**：有 200 tokens 的安全边际兜底，近似误差不会导致溢出
3. **无外部依赖**：不需要引入 Python binding 或 CGO

这是个典型的工程权衡：用 200 tokens 的安全边际换掉一个复杂的精确 tokenizer，ROI 非常高。

## 写在最后

Token 预算分配本质上是一个**在线装箱问题**（Online Bin Packing）。但我们不需要最优解——贪心策略 + 安全边际 + 优先级排序就够用了。

核心原则就三条：

1. **刚性支出先扣**（响应预留、安全边际）
2. **高优先级先分配**（检索上下文 > 会话记忆）
3. **宁可少塞一点，也不要溢出**（安全边际兜底）

简单，但很实用。
