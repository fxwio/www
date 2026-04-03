---
title: "RAG 文档摄入的 5 阶段并发 Pipeline 怎么设计"
description: "解析 → 分 chunk → 攒批 → embedding → 入库，每个阶段独立伸缩"
pubDatetime: 2026-03-06T21:29:00+08:00
author: Fuxiang Wang
tags:
  - rag
  - pipeline
  - ingestion
draft: false
hideEditPost: true
timezone: Asia/Shanghai
---

> 解析 → 分 chunk → 攒批 → embedding → 入库，每个阶段独立伸缩

## 问题

要把一批文档塞进 RAG 系统，需要经过很多步：解析文档提取文本、切分成小块、调 embedding 接口算向量、存到向量库和搜索库。

如果串行做，一批 100 个文档要等每个文档走完全流程才开始下一个。更要命的是，embedding 接口有限流——你不可能一次性发 100 个请求上去。

所以我在 [Shoal](https://github.com/fxwio/shoal) 里设计了一个 **5 阶段并发 Pipeline**：每个阶段用 channel 连接，用独立的 worker pool 并发执行。

## Pipeline 架构

![5 阶段摄入 Pipeline](/diagrams/blog-08-ingestion-pipeline.svg)

```
docs → [Parse Workers] → [Chunk Workers] → [Batch Aggregator] → [Embed Workers] → [Index Workers]
          ↓                    ↓                   ↓                    ↓                  ↓
        docCh             parsedCh              chunkCh            embedReqCh          embeddedCh
```

5 个阶段：

1. **Parse**：解析文档（PDF/HTML/文本），提取纯文本
2. **Chunk**：把长文本切成固定大小的小块
3. **Batch Aggregator**：把零散的 chunks 攒成批次（batch size 可配）
4. **Embed**：调 embedding API，带令牌桶限流
5. **Index**：写入 pgvector + tsvector 两个存储

## channel 编排

核心代码就是 channel + WaitGroup 的编排：

```go
// shoal/internal/service/ingestion/service.go

func (s *Service) Ingest(ctx context.Context, docs []domain.SourceDocument) (domain.IngestResult, error) {
    // 每个 channel 的 buffer = workers * 2，给上游一点缓冲空间
    docCh := make(chan domain.SourceDocument, channelBuffer(s.cfg.Ingestion.ParseWorkers))
    parsedCh := make(chan parsedItem, channelBuffer(s.cfg.Ingestion.ChunkWorkers))
    chunkCh := make(chan chunkItem, channelBuffer(s.cfg.Ingestion.EmbedWorkers))
    embedReqCh := make(chan embedRequest, channelBuffer(s.cfg.Ingestion.EmbedWorkers))
    embeddedCh := make(chan embeddedBatch, channelBuffer(s.cfg.Ingestion.IndexWorkers))

    // 每个阶段一个 WaitGroup
    var parseWG, chunkWG, embedWG, indexWG sync.WaitGroup
```

`channelBuffer = workers * 2` 是个经验值——让上游 worker 完成一个任务后可以立即投递结果，不会因为下游满了而阻塞。

## 攒批阶段：BatchSize + FlushInterval 双触发

Embedding API 支持批量调用（一次传多个文本），所以在 Chunk 和 Embed 之间加了一个攒批器：

```go
go func() {
    defer close(embedReqCh)

    ticker := time.NewTicker(s.cfg.Ingestion.EmbedFlushInterval)  // 500ms
    defer ticker.Stop()

    var pending []domain.Chunk
    flush := func() {
        if len(pending) == 0 { return }
        batch := append([]domain.Chunk(nil), pending...)
        pending = nil
        embedReqCh <- embedRequest{chunks: batch}
    }

    for {
        select {
        case item, ok := <-chunkCh:
            if !ok {
                flush()  // 上游关闭 → 刷出残留
                return
            }
            pending = append(pending, item.chunks...)
            if len(pending) >= s.cfg.Ingestion.EmbedBatchSize {
                flush()  // 攒够了 → 立即刷出
            }
        case <-ticker.C:
            flush()  // 超时 → 刷出（避免尾部数据等太久）
        }
    }
}()
```

两个触发条件：

- **数量触发**：攒够 `EmbedBatchSize`（比如 8 个 chunk）立即刷
- **时间触发**：超过 `EmbedFlushInterval`（比如 500ms）兜底刷

这样即使最后一批只有 2 个 chunk，也不会一直等。

## Embedding 限流：channel 式令牌桶

Embedding API 有请求频率限制。直接在 Embed Worker 里加了令牌桶限流：

```go
// 创建令牌桶：5 QPS，burst 2
limiter := newTokenBucket(s.cfg.Ingestion.EmbedRequestsPerSecond, s.cfg.Ingestion.EmbedBurst)
defer limiter.Stop()

// Embed Worker
for req := range embedReqCh {
    if err := limiter.Wait(ctx); err != nil {  // 阻塞等 token
        fail(...)
        return
    }
    vectors, err := s.embedder.Embed(retryCtx, req.chunks)
    // ...
}
```

这个令牌桶的实现也很简洁——用 channel 做令牌容器：

```go
type tokenBucket struct {
    tokens chan struct{}
    stopCh chan struct{}
}

func newTokenBucket(rps int, burst int) *tokenBucket {
    tb := &tokenBucket{
        tokens: make(chan struct{}, burst),  // channel 容量 = burst
    }
    // 初始填满
    for i := 0; i < burst; i++ {
        tb.tokens <- struct{}{}
    }
    // 定时补充
    interval := time.Second / time.Duration(rps)
    go func() {
        ticker := time.NewTicker(interval)
        for {
            select {
            case <-tb.stopCh: return
            case <-ticker.C:
                select {
                case tb.tokens <- struct{}{}: // 补充 1 个 token
                default: // 桶满了，丢弃
                }
            }
        }
    }()
    return tb
}

func (t *tokenBucket) Wait(ctx context.Context) error {
    select {
    case <-ctx.Done(): return ctx.Err()
    case <-t.tokens: return nil  // 拿到 token，放行
    }
}
```

用 channel 做令牌桶的好处：`Wait` 天然支持 `context` 取消，不需要额外的 select-case。

## 幂等清理 + 失败记录

文档可能被重复摄入（比如更新了内容）。Index 阶段会先删除旧数据，用 `sync.Map` 保证每个文档只清理一次：

```go
func (s *Service) indexBatch(ctx context.Context, batch embeddedBatch, cleanedDocuments *sync.Map) error {
    for _, ref := range batch.refs {
        // LoadOrStore 保证幂等
        if _, loaded := cleanedDocuments.LoadOrStore(key, struct{}{}); loaded {
            continue  // 已经清理过了
        }
        s.deleteExistingDocument(ctx, ref.filter, ref.documentID)
    }
    // 然后 upsert 新数据...
}
```

每个阶段的失败都会记录到 `IngestionFailureRecorder`，包括文档 ID、阶段名、错误信息、时间戳。上层可以查询哪些文档失败了，做针对性重试。

## Pipeline 的关闭顺序

关闭顺序必须是**从上游到下游**的，否则会死锁或丢数据：

```go
// 输入完成 → 关闭 docCh
go func() {
    defer close(docCh)
    for _, doc := range docs { docCh <- doc }
}()

// Parse 完成 → 关闭 parsedCh
go func() { parseWG.Wait(); close(parsedCh) }()

// Chunk 完成 → 关闭 chunkCh
go func() { chunkWG.Wait(); close(chunkCh) }()

// Aggregator 检测到 chunkCh 关闭 → flush 残留 → 关闭 embedReqCh

// Embed 完成 → 关闭 embeddedCh
go func() { embedWG.Wait(); close(embeddedCh) }()

// Index 完成 → 信号 doneCh
go func() { indexWG.Wait(); close(doneCh) }()
```

每个阶段 `range` 上游的 channel，上游 close 后 `range` 自动退出。层层传递，优雅关闭。

## 写在最后

Go 的 channel + goroutine 天生适合做这种多阶段 Pipeline。每个阶段独立伸缩（调配 worker 数量就行），channel buffer 解耦上下游速率差异，`sync.WaitGroup` 保证关闭顺序。

设计原则就三条：

1. **阶段之间不共享内存**，只通过 channel 通信
2. **每个阶段独立配置 workers**，瓶颈在哪里就加哪里的 workers
3. **关闭从上游到下游传递**，不要从下游主动 close 上游的 channel
