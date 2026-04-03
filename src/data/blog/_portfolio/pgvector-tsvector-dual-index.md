---
title: "一个 PostgreSQL 怎么同时搞定向量检索和全文检索"
description: "pgvector + tsvector 双索引，一个数据库解决 RAG 的全部存储需求"
pubDatetime: 2026-03-13T15:07:00+08:00
author: Fuxiang Wang
tags:
  - rag
  - postgresql
  - pgvector
draft: false
hideEditPost: true
timezone: Asia/Shanghai
---

> pgvector + tsvector 双索引，一个数据库解决 RAG 的全部存储需求

## 为什么不用 Milvus + Elasticsearch

很多 RAG 教程推荐向量库用 Milvus/Pinecone，全文检索用 Elasticsearch。这样你要维护两套存储，数据一致性靠同步保证——两个库的数据可能因为同步延迟而不一致。

对于企业知识库场景（几十万到百万文档），其实 **PostgreSQL 一个库就能搞定两种检索**：

- **向量检索**：pgvector 扩展，支持余弦距离、欧几里得距离
- **全文检索**：原生 tsvector + GIN 索引

好处：一个数据库、一份运维、事务保证数据一致性、多租户隔离用 WHERE 条件就够了。

## 向量存储：pgvector

先看建表（简化）：

```sql
CREATE TABLE vector_chunks(
    chunk_id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL,
    tenant_id TEXT NOT NULL,
    knowledge_base_id TEXT NOT NULL,
    content TEXT NOT NULL,
    metadata JSONB,
    vector_dims INT,
    vector_data JSONB,        -- 原始向量（JSON 数组，用于 fallback 计算）
    embedding vector(1536)     -- pgvector 类型，用于近邻检索
);

CREATE INDEX ON vector_chunks USING ivfflat (embedding vector_cosine_ops);
```

![双索引存储架构](/diagrams/blog-09-dual-index.svg)

检索时，先把 query 做 embedding，再用 pgvector 的 `<=>` 操作符做余弦距离排序：

```go
// shoal/internal/repository/postgres/vector_store.go

func (s *VectorStore) Search(ctx context.Context, query string, topK int, filter domain.SearchFilter) ([]domain.SearchHit, error) {
    // 1. 先把 query 文本转成向量
    embeddedQuery, _ := s.embedder.Embed(ctx, []domain.Chunk{{Content: query}})
    queryVector := embeddedQuery[0].Vector

    // 2. 用 pgvector 做近邻搜索
    rows, _ := s.db.QueryContext(ctx, `
        SELECT chunk_id, content, metadata,
               1 - (embedding <=> $3::vector) AS score   -- 余弦相似度
        FROM vector_chunks
        WHERE tenant_id = $1
          AND knowledge_base_id = $2
        ORDER BY embedding <=> $3::vector ASC
        LIMIT $4
    `, filter.TenantID, filter.KnowledgeBaseID, vectorLiteral(queryVector), topK)
    // ...
}
```

几个细节：

1. **`1 - (embedding <=> $3::vector)`**：`<=>` 返回的是余弦距离（0~2），转成相似度（-1~1）要用 `1 - distance`
2. **vectorLiteral**：Go 的 `[]float32` 转成 pgvector 能识别的字符串格式 `[0.1,0.2,...]`
3. **IVFFlat 索引**：适合百万级数据，创建快，查询延迟毫秒级。HNSW 精度更高但建索引更慢
4. **余弦相似度 fallback**：pgvector 偶尔会返回 score=0（索引命中但距离计算异常），所以代码里有个手动计算的兜底

```go
if hit.Score == 0 {
    hit.Score = cosineSimilarity(queryVector, vector)  // 手动计算 fallback
}
```

## 全文存储：tsvector + GIN

全文检索用 PostgreSQL 原生能力：

```sql
CREATE TABLE search_chunks(
    chunk_id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL,
    tenant_id TEXT NOT NULL,
    knowledge_base_id TEXT NOT NULL,
    sequence INT,
    content TEXT NOT NULL,
    metadata JSONB,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('simple', content)) STORED
);

CREATE INDEX ON search_chunks USING GIN (search_vector);
```

`search_vector` 是一个**自动生成的计算列**：每次 content 更新都自动重建索引，不需要手动维护。

检索 SQL 有个巧妙的设计——**双路匹配**：

```go
// shoal/internal/repository/postgres/search_store.go

rows, _ := s.db.QueryContext(ctx, `
    SELECT chunk_id, content, metadata,
           ts_rank_cd(search_vector, plainto_tsquery('simple', $1)) +
           CASE WHEN content ILIKE '%' || $1 || '%' THEN 1 ELSE 0 END AS score
    FROM search_chunks
    WHERE tenant_id = $2 AND knowledge_base_id = $3
      AND (
        search_vector @@ plainto_tsquery('simple', $1)   -- tsvector 匹配
        OR content ILIKE '%' || $1 || '%'                -- 原文 LIKE 兜底
      )
    ORDER BY score DESC, sequence ASC
    LIMIT $4
`, query, filter.TenantID, filter.KnowledgeBaseID, topK)
```

为什么要 **tsvector + ILIKE 双路**？

- `tsvector` 做分词匹配，效率高（走 GIN 索引），但对中文支持依赖分词器配置
- `ILIKE` 做原文子串匹配，能兜住分词遗漏的情况（比如专有名词、版本号）

分数计算也是双路加权：`ts_rank_cd` 给一个基础分，如果原文也包含 query 则加 1 分。这样同时匹配两路的文档排名更高。

## 多租户隔离

两张表都有 `tenant_id` 和 `knowledge_base_id` 字段，所有查询都带 WHERE 条件：

```sql
WHERE tenant_id = $1 AND knowledge_base_id = $2
```

不需要 Row-Level Security，不需要分表。对于企业知识库这个量级，加个复合索引就够了：

```sql
CREATE INDEX ON vector_chunks (tenant_id, knowledge_base_id);
CREATE INDEX ON search_chunks (tenant_id, knowledge_base_id);
```

## Upsert：幂等写入

写入用 `ON CONFLICT DO UPDATE`，天然幂等：

```go
tx.ExecContext(ctx, `
    INSERT INTO vector_chunks(chunk_id, ..., embedding)
    VALUES ($1, ..., $9::vector)
    ON CONFLICT (chunk_id) DO UPDATE SET
        content = EXCLUDED.content,
        embedding = EXCLUDED.embedding
`, ...)
```

同一个 chunk_id 重复写入会覆盖旧数据，不会报错。配合摄入 Pipeline 的幂等清理，整个流程是可以安全重跑的。

## 写在最后

pgvector + tsvector 的组合不是银弹——千万级以上文档可能需要更专业的向量数据库。但对于大多数企业知识库场景，这个方案的**运维复杂度最低**，且性能足够：

- 混合检索本地处理 < 50ms
- HTTP 吞吐 ~6 万 QPS

一个数据库，两种索引，零中间件依赖。够用的方案就是最好的方案。
