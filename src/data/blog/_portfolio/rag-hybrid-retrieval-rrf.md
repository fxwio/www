---
title: "RAG 检索到底怎么做到又准又全——混合检索 + RRF 融合实战"
description: "向量检索和全文检索各有盲区，双路并行 + RRF 融合才是正解"
pubDatetime: 2025-12-05T22:18:00+08:00
author: Fuxiang Wang
tags:
  - rag
  - retrieval
  - postgresql
draft: false
hideEditPost: true
timezone: Asia/Shanghai
---

> 向量检索和全文检索各有盲区，双路并行 + RRF 融合才是正解

## 只用一种检索，迟早翻车

做 RAG 系统的时候，检索这一步是最关键的——检索质量直接决定了 LLM 回答的质量。

但问题是，常见的两种检索各有盲区：

- **向量检索**：语义理解强，"如何部署服务"能匹配到"应用上线流程"。但精确关键词不行——搜"v2.3.1"可能什么都匹配不到，因为版本号在向量空间里没什么语义。
- **全文检索**：关键词精准匹配，BM25 算法久经考验。但语义理解弱——搜"怎么扩容"匹配不到"水平伸缩方案"。

所以我在 [Shoal](https://github.com/fxwio/shoal)（RAG 引擎）里做了混合检索：两路并行跑，结果用 RRF 融合。

## 整体架构

![混合检索架构图](/diagrams/blog-02-hybrid-retrieval-arch.svg)

用户的查询同时发给两个检索分支：

1. **向量分支**：query → embedding → pgvector 近邻搜索 → Top-K 候选
2. **全文分支**：query → PostgreSQL tsvector 全文检索 → Top-K 候选

两路的候选结果送到 RRF（Reciprocal Rank Fusion）融合，输出最终的 Top-K。

关键设计：**两路是并发的**，不是串行的。这意味着混合检索的延迟约等于较慢那一路，而不是两路之和。

## 并发检索：goroutine 双路并行

代码很直接，用 goroutine + channel 做并发：

```go
// shoal/internal/service/retrieval/service.go

func (s *Service) Retrieve(ctx context.Context, query domain.SearchQuery) (domain.RetrievalResult, error) {
    callCtx, cancel := context.WithTimeout(ctx, s.cfg.Timeouts.Retrieval)
    defer cancel()

    results := make(chan namedResult, 2)
    var wg sync.WaitGroup

    run := func(name string, fn func(context.Context) ([]domain.SearchHit, error)) {
        wg.Add(1)
        go func() {
            defer wg.Done()
            // 每个分支有独立超时，不会互相拖累
            branchCtx, cancel := context.WithTimeout(callCtx, s.cfg.Timeouts.RetrievalBranch)
            defer cancel()
            hits, err := fn(branchCtx)
            results <- namedResult{name: name, hits: hits, err: err}
        }()
    }

    // 两路并发启动
    run("search", func(execCtx context.Context) ([]domain.SearchHit, error) {
        return s.searchDB.Search(execCtx, effective.Query, s.cfg.Retrieval.SearchTopK, effective.Filter)
    })
    run("vector", func(execCtx context.Context) ([]domain.SearchHit, error) {
        return s.vectorDB.Search(execCtx, effective.Query, s.cfg.Retrieval.VectorTopK, effective.Filter)
    })

    go func() {
        wg.Wait()
        close(results)
    }()

    // 收集结果，容忍单路失败
    for result := range results {
        if result.err != nil {
            continue  // 一路挂了另一路还能用
        }
        // 按名字分流 ...
    }

    // 只要有一路成功就能融合
    if succeeded == 0 {
        return domain.RetrievalResult{}, fmt.Errorf("all recall branches failed")
    }

    fused, _ := s.fusion.Fuse(callCtx, textHits, vectorHits, effective.TopK)
    return domain.RetrievalResult{Hits: fused}, nil
}
```

几个值得注意的点：

1. **每个分支有独立超时**（`RetrievalBranch`），避免一路慢了拖死另一路
2. **容忍单路失败**：向量库挂了，全文检索还能兜底，反之亦然
3. **channel buffer = 2**：正好两路结果，不会阻塞

## RRF 融合：为什么不用简单加权

两路检索出来的分数不在同一个量纲上——向量检索返回的是余弦相似度（0~1），全文检索返回的是 BM25 分数（可以是任意正数）。直接加权平均？权重怎么定？不同 query 的最优权重还不一样。

RRF（Reciprocal Rank Fusion）解决了这个问题，它**只看排名，不看分数**。

![RRF 计分示意图](/diagrams/blog-02-rrf-scoring.svg)

公式很简单：

```
RRF_score(d) = Σ 1 / (k + rank_i(d))
```

- `k` 是平滑参数（我用 60，这是经验值）
- `rank_i(d)` 是文档 d 在第 i 路检索结果中的排名

直觉是：一个文档如果在两路检索中排名都靠前，融合后的分数就高。在某一路排名很前、另一路没出现，也能拿到分数，但不如两路都出现的。

看代码实现：

```go
// shoal/internal/service/retrieval/service.go

type RRFFusion struct {
    K int  // 平滑参数，默认 60
}

func (r RRFFusion) Fuse(ctx context.Context, textHits []domain.SearchHit, vectorHits []domain.SearchHit, topK int) ([]domain.SearchHit, error) {
    merged := make(map[string]aggregate)

    accumulate := func(branch string, hits []domain.SearchHit) {
        for idx, hit := range hits {
            existing := merged[hit.ChunkID]
            if existing.hit.ChunkID == "" {
                existing.hit = hit
            }
            // 核心公式：1 / (k + rank)
            existing.hit.FusedScore += 1.0 / float64(r.K+idx+1)
            // 记录每路的排名，方便调试
            existing.hit.Metadata["rrf_branch_"+branch+"_rank"] = fmt.Sprintf("%d", idx+1)
            merged[hit.ChunkID] = existing
        }
    }

    accumulate("search", textHits)
    accumulate("vector", vectorHits)

    // 按融合分数降序排列
    sort.SliceStable(output, func(i, j int) bool {
        if output[i].FusedScore == output[j].FusedScore {
            return output[i].Score > output[j].Score  // 同分时看原始分数
        }
        return output[i].FusedScore > output[j].FusedScore
    })

    // 截取 Top-K
    if len(output) > topK {
        output = output[:topK]
    }
    return output, nil
}
```

注意一个细节：每条结果的 Metadata 里会记录 `rrf_branch_search_rank` 和 `rrf_branch_vector_rank`。这不是功能需要，但调试的时候特别有用——你可以看到某个文档在两路中分别排第几，理解融合结果为什么是这个顺序。

## 一个 PostgreSQL 搞定两种检索

很多 RAG 系统用 Milvus/Pinecone 做向量检索，Elasticsearch 做全文检索，架构复杂，运维成本高。

我的方案：**PostgreSQL 一个库同时搞定**。

- **向量检索**：pgvector 扩展，IVFFlat 索引。适合百万级文档，检索延迟毫秒级
- **全文检索**：原生 tsvector + GIN 索引。BM25 级别的检索质量，不需要额外中间件

好处是显而易见的：

- 一个数据库，一份运维
- 数据一致性天然保证——不需要同步两个存储
- 事务支持，多租户隔离靠 SQL WHERE 条件就够了

当然也有局限：如果文档量到了千万级，pgvector 可能扛不住，得换 HNSW 或者独立的向量数据库。但对于企业知识库场景（几十万到百万文档），这个方案性价比很高。

## 实际效果

基准测试数据（本地 PostgreSQL，100K 文档）：

| 指标                 | 数值      |
| -------------------- | --------- |
| 混合检索本地处理延迟 | < 50ms    |
| HTTP 层吞吐          | ~6 万 QPS |
| P99 延迟             | < 4ms     |

50ms 以内完成两路检索 + RRF 融合，对于 RAG 场景绰绰有余（LLM 生成才是瓶颈，通常需要几秒）。

## 写在最后

混合检索的核心思路就一句话：**用不同视角看同一个 query，然后让排名来投票**。

向量检索看语义，全文检索看关键词，RRF 做民主投票。两路都说好的文档排前面，只有一路说好的也不会被遗漏。

实现上没有什么黑科技，就是并发 + 融合 + 一个数据库。越简单的架构越不容易出问题。
