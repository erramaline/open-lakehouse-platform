# ADR-003: Why Docling (IBM) over Unstructured-IO for Document Ingestion

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-03-12 |
| **Deciders** | Principal Data Platform Architect, Data Engineering Lead, AI/ML Lead |
| **Tags** | ingestion, document-parsing, nlp, licensing |

---

## Context

The platform ingests heterogeneous document types — PDFs (native text and scanned), DOCX, PPTX, HTML, EPUB, and image-heavy technical documents — and converts them into structured data suitable for Iceberg tables and analytics workloads. The document parser must:

1. Extract structured text, tables, figures, and metadata with high fidelity.
2. Handle complex layouts (multi-column PDFs, mixed text+image pages, scanned documents via OCR).
3. Output structured formats compatible with downstream pipelines (JSON, Parquet/Arrow, Markdown).
4. Be deployable as a stateless, horizontally scalable worker in Kubernetes.
5. Be 100% open source under Apache 2.0. **No API key dependencies, no SaaS calls for core processing.**
6. Actively maintained with a clear governance model.

Two libraries were evaluated in depth: **Docling (IBM)** and **Unstructured-IO**.

---

## Decision

**We adopt Docling (IBM Research, latest stable) as the document parsing engine for all ingestion workers.**

---

## License Comparison

| Criterion | Docling (IBM) | Unstructured-IO |
|---|---|---|
| Core library license | **Apache 2.0** | **Apache 2.0** |
| Self-hosted API server license | Apache 2.0 (all open) | Apache 2.0 |
| Hosted inference dependency | None — fully offline | Optional SaaS API (unstructured.io) |
| Enterprise feature gating | None | EE features behind commercial tier |
| Model weights license | Permissive (IBM research models) | Mixed — some models require API key |
| Governance | IBM Research open source + ASF-adjacent community | Unstructured-IO Inc. (VC-backed) |

**Analysis:** While Unstructured-IO's core library is Apache 2.0, the product is built around a hosted API (unstructured.io) as the primary offering. Complex document types (high-quality OCR on scanned PDFs, table extraction) require either the hosted API or the "Unstructured Enterprise" self-hosted server. This introduces a de-facto SaaS dependency for production-quality parsing of the document types our platform must handle.

Docling is purely self-hosted and requires no external API calls. All models (layout analysis, table structure recognition, OCR) are bundled or downloaded once and served locally.

---

## Capability Comparison

| Feature | Docling (IBM) | Unstructured-IO |
|---|---|---|
| Native PDF text extraction | ✅ | ✅ |
| Scanned PDF (OCR) | ✅ (Tesseract + EasyOCR) | ✅ (requires hosted or EE for quality) |
| Table extraction (structured) | ✅ (TableTransformer, high accuracy) | ✅ (partial in OSS tier) |
| DOCX / PPTX | ✅ | ✅ |
| HTML | ✅ | ✅ |
| Figure detection & captioning | ✅ | Partial |
| Output: Markdown | ✅ | ✅ |
| Output: JSON (structured) | ✅ (DoclingDocument model) | ✅ |
| Output: Arrow / Parquet | ✅ (via DoclingDocument → to_df()) | Partial (extra step) |
| Layout analysis model | DiT (Document Image Transformer, IBM) | Detectron2-based |
| Multi-language OCR | ✅ (EasyOCR — 80+ languages) | English-primary (OSS) |
| Chunking for RAG | ✅ (hierarchical, sentence-based) | ✅ |
| Batch / async processing | ✅ | ✅ |
| GPU acceleration | ✅ | ✅ |
| K8s stateless worker model | ✅ | ✅ |
| Offline / air-gapped | ✅ (all models local) | ❌ (requires API for full quality) |

---

## Consequences

### Positive
- **Fully offline:** All models execute locally. No egress to external APIs. Critical for air-gapped environments and data sovereignty requirements.
- **Apache 2.0 throughout:** No feature tiering, no commercial upgrade path required. Satisfies our global OSS constraint.
- **Superior table extraction:** IBM's TableTransformer provides state-of-the-art table structure recognition — critical for ingesting financial and regulatory documents.
- **Rich structured output:** `DoclingDocument` model provides hierarchical document structure (sections, headings, tables, figures) directly mappable to Iceberg schemas.
- **Parquet/Arrow native export:** `to_df()` method produces pandas DataFrames suitable for direct Parquet write to MinIO.
- **Multi-language support:** EasyOCR backend supports 80+ languages — required for international document ingestion.
- **IBM Research backing:** Active research investment; reproducible academic benchmarks available.

### Negative
- **Model download on first run:** DiT and TableTransformer model weights (~500 MB) must be pre-baked into the Docker image or fetched from an internal model registry. Adds CI build time.
- **GPU recommended for large volumes:** CPU-only processing is possible but slow for scanned PDFs at scale. Requires GPU node pool in K8s for high-throughput ingestion.
- **Smaller community than Unstructured-IO:** Fewer Stack Overflow answers; support comes primarily from GitHub Issues and IBM Research contacts.

### Neutral
- Airflow DAG wraps Docling as a Python operator; no architectural dependency on Docling's internal API stability beyond the public `DocumentConverter` class.

---

## Alternatives Considered

### Unstructured-IO
- **Rejected:** Production-quality table extraction requires hosted API or Enterprise tier. SaaS API dependency violates our zero-external-dependency constraint for core processing. OSS tier insufficient for complex PDF layouts (financial reports, scanned regulatory filings).

### Apache Tika
- **Rejected:** Text extraction only. No layout analysis, no table extraction, no figure detection. Output is unstructured plain text. Insufficient for our structured ingestion requirements.

### PyMuPDF (fitz) + custom pipeline
- **Rejected:** Low-level; requires engineering a custom layout analysis pipeline. Duplicates work already done by Docling. Maintenance burden unacceptable.

### pdfplumber / pdfminer.six
- **Rejected:** Text + basic table heuristics only. No ML-backed layout analysis. Fragile on complex PDFs. Not suitable for production ingestion of heterogeneous document corpora.

### LlamaParse (LlamaIndex)
- **Rejected:** Hosted API only (no self-hosted option as of evaluation date). Violates offline/air-gapped requirement and data sovereignty policy.

---

## References
- [Docling GitHub (IBM Research)](https://github.com/DS4SD/docling)
- [Docling paper: "Docling Technical Report" (IBM, 2024)](https://arxiv.org/abs/2408.09869)
- [Unstructured-IO GitHub](https://github.com/Unstructured-IO/unstructured)
- [TableTransformer (Microsoft/IBM)](https://github.com/microsoft/table-transformer)
- ADR-009 — Audit trail (document processing logs)
