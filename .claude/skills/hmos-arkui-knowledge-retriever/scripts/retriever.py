"""
ArkUI Retriever

Keyword + synonym + rerank retrieval for ArkUI knowledge base.
No external dependencies, no vector embeddings required.
"""

import os
import json
import re
from typing import List, Dict, Optional
from dataclasses import dataclass

from document_loader import CodeExtractor

DEFAULT_MAX_CONTENT_CHARS = 1200
DEFAULT_MAX_TOTAL_CHARS = 10000


@dataclass
class SearchResult:
    id: str
    content: str
    score: float
    source: str
    title: str
    category: str
    metadata: Dict


@dataclass
class RetrievalResult:
    query: str
    documents: List[SearchResult]
    context: str
    code_examples: List[Dict]
    suggested_queries: List[str]


class ArkUIRetriever:

    DEFAULT_RERANK_WEIGHTS = {
        "direct_hit": 0.20,
        "keyword_coverage": 0.30,
        "title_phrase": 0.15,
        "source_phrase": 0.10,
    }

    def __init__(self, knowledge_dir: str = "."):
        self.knowledge_dir = knowledge_dir
        self.code_extractor = CodeExtractor()
        self._seen_doc_ids: Dict[str, str] = {}
        self._load_index()
        self._build_synonyms()
        self._build_lookups()

    def _load_index(self):
        index_path = os.path.join(self.knowledge_dir, ".system", "INDEX.json")
        if os.path.exists(index_path):
            with open(index_path, "r", encoding="utf-8") as f:
                self._index_data = json.load(f)
                self.documents_index = self._index_data.get("documents", [])
                self.component_map = self._index_data.get("component_map", {})
                self.keyword_map = self._index_data.get("keyword_map", {})
        else:
            self._index_data = {}
            self.documents_index = []
            self.component_map = {}
            self.keyword_map = {}

    def _build_synonyms(self):
        self.synonym_lookup = {}
        for group in self._index_data.get("synonym_groups", []):
            expanded = [t.lower() for t in group]
            for term in expanded:
                if term not in self.synonym_lookup:
                    self.synonym_lookup[term] = set()
                for other in expanded:
                    if other != term:
                        self.synonym_lookup[term].add(other)

    def _build_lookups(self):
        self._filename_to_docs = {}
        for doc in self.documents_index:
            fn = doc.get("filename", "")
            if fn not in self._filename_to_docs:
                self._filename_to_docs[fn] = []
            self._filename_to_docs[fn].append(doc)

        self._path_prefix_to_docs = {}
        for doc in self.documents_index:
            path = doc.get("path", "")
            parts = path.split("/")
            for i in range(1, len(parts) + 1):
                prefix = "/".join(parts[:i])
                if prefix not in self._path_prefix_to_docs:
                    self._path_prefix_to_docs[prefix] = []
                self._path_prefix_to_docs[prefix].append(doc)

    MUST_SEARCH_PATTERNS = [
        r"@ComponentV2|@Local|@Param|@Provider|@Consumer|@Monitor|@Computed|@ObservedV2|@Trace|@ReusableV2",
        r"状态管理\s*V2|V2\s*状态|V2装饰器",
        r"Navigation|NavDestination|NavRouter|页面跳转|页面路由",
        r"LazyForEach|Repeat|渲染控制|IDataSource",
        r"错误码|errorcode|error\s*code",
        r"废弃|deprecated|替代\s*方案",
        r"保留字|框架保留|framework.*keep|keep.*word",
        r"性能优化|性能\s*调优|performance",
        r"API\s*(version\s*)?12|API\s*(version\s*)?13|API\s*(version\s*)?14|API\s*(version\s*)?15",
        r"aboutToAppear|aboutToDisappear|onPageShow|onPageHide|生命周期",
    ]

    SHOULD_SEARCH_PATTERNS = [
        r"属性表|完整属性|所有属性|属性列表",
        r"transition|sharedTransition|转场动画|页面转场",
        r"GestureGroup|TapGesture|LongPressGesture|PanGesture|PinchGesture|手势",
        r"bindSheet|bindMenu|AlertDialog|ActionSheet|CustomDialog|弹窗|菜单",
        r"RenderNode|FrameNode|自定义节点|NodeContainer",
        r"窗口管理|WindowStage|windowClass",
        r"组件生命周期|自定义组件.*生命周期",
    ]

    def assess_search_necessity(self, query: str) -> Dict:
        query_lower = query.lower()

        for pattern in self.MUST_SEARCH_PATTERNS:
            if re.search(pattern, query, re.IGNORECASE):
                matched_pattern = pattern.split("|")[0]
                return {
                    "level": "must",
                    "reason": f"命中必须检索话题: {matched_pattern}",
                    "action": "必须检索知识库后再回答",
                }

        for pattern in self.SHOULD_SEARCH_PATTERNS:
            if re.search(pattern, query, re.IGNORECASE):
                matched_pattern = pattern.split("|")[0]
                return {
                    "level": "should",
                    "reason": f"命中建议检索话题: {matched_pattern}",
                    "action": "建议检索知识库以确保准确性",
                }

        return {
            "level": "skip",
            "reason": "话题属于基础组件/布局/通用概念",
            "action": "可基于自身知识回答，标注'未检索知识库'",
        }

    def clear_seen(self):
        self._seen_doc_ids = {}

    def retrieve(
        self,
        query: str,
        k: int = 3,
        filters: Optional[Dict] = None,
        rerank_weights: Optional[Dict] = None,
        max_content_chars: int = DEFAULT_MAX_CONTENT_CHARS,
        max_total_chars: int = DEFAULT_MAX_TOTAL_CHARS,
        dedup: bool = True,
        compact: bool = True,
    ) -> RetrievalResult:
        weights = self.DEFAULT_RERANK_WEIGHTS.copy()
        if rerank_weights:
            for key in weights:
                if key in rerank_weights and rerank_weights[key] is not None:
                    weights[key] = float(rerank_weights[key])

        candidates = self._generate_candidates(query)
        query_tokens = self._tokenize_query(query)
        direct_ids = {
            c["doc_id"]
            for c in candidates
            if c["match_type"] in ("component", "keyword")
        }
        ranked = self._rerank_candidates(
            candidates, query, query_tokens, direct_ids, weights
        )

        top_ids = [r["doc_id"] for r in ranked[:k]]
        if dedup:
            top_ids = [did for did in top_ids if did not in self._seen_doc_ids]

        results = self._load_results(top_ids, ranked, query_tokens, max_content_chars, max_total_chars, compact)

        for r in results:
            self._seen_doc_ids[r.id] = r.source

        if filters:
            results = self._apply_filters(results, filters)

        return RetrievalResult(
            query=query,
            documents=results,
            context=self._build_context(results),
            code_examples=self._extract_code_examples(results),
            suggested_queries=self._generate_suggestions(query, results),
        )

    def _generate_candidates(self, query: str) -> List[Dict]:
        query_lower = query.lower()
        seen = set()
        candidates = []

        def _add(doc_info, score, match_type):
            did = doc_info["id"]
            if did not in seen:
                seen.add(did)
                candidates.append(
                    {
                        "doc_id": did,
                        "doc_info": doc_info,
                        "initial_score": score,
                        "match_type": match_type,
                    }
                )

        for comp, files in self.component_map.items():
            if comp.lower() in query_lower:
                for fn in files:
                    for doc in self._filename_to_docs.get(fn, []):
                        _add(doc, 1.0, "component")

        for kw, patterns in self.keyword_map.items():
            if kw in query:
                for pat in patterns:
                    for doc in self._path_prefix_to_docs.get(pat, []):
                        _add(doc, 0.9, "keyword")

        tokens = re.findall(r"[a-zA-Z0-9_]+", query_lower) + re.findall(
            r"[\u4e00-\u9fff]{2,}", query
        )
        if tokens:
            for doc in self.documents_index:
                if doc["id"] in seen:
                    continue
                t = doc.get("title", "").lower()
                f = doc.get("filename", "").lower()
                hits = sum(1 for tok in tokens if tok in t or tok in f)
                if hits:
                    _add(doc, 0.6 + 0.2 * (hits / len(tokens)), "title_match")

        for term, expansions in self.synonym_lookup.items():
            if term in query_lower and expansions:
                for doc in self.documents_index:
                    if doc["id"] in seen:
                        continue
                    t = doc.get("title", "").lower()
                    f = doc.get("filename", "").lower()
                    if any(e in t or e in f for e in expansions):
                        _add(doc, 0.5, "synonym")

        return candidates

    def _tokenize_query(self, query: str) -> List[str]:
        tokens = re.findall(r"[a-zA-Z0-9_]+", query.lower()) + re.findall(
            r"[\u4e00-\u9fff]{2,}", query
        )
        seen, out = set(), []
        for t in tokens:
            t = t.strip()
            if len(t) >= 2 and t not in seen:
                seen.add(t)
                out.append(t)
        return out

    def _rerank_candidates(self, candidates, query, query_tokens, direct_ids, weights):
        query_lower = query.lower()
        ranked = []

        for c in candidates:
            info = c["doc_info"]
            title = info.get("title", "").lower()
            source = info.get("path", "").lower()
            cat = info.get("category", "").lower()
            score = c["initial_score"]

            is_direct = c["doc_id"] in direct_ids
            if is_direct:
                score += weights["direct_hit"]

            haystack = f"{title} {source} {cat}"
            kw_hits = sum(1 for tok in query_tokens if tok in haystack)
            if query_tokens:
                score += min(
                    weights["keyword_coverage"],
                    (kw_hits / len(query_tokens)) * weights["keyword_coverage"],
                )

            if query_lower in title:
                score += weights["title_phrase"]
            if query_lower in source:
                score += weights["source_phrase"]

            ranked.append(
                {
                    "doc_id": c["doc_id"],
                    "doc_info": info,
                    "match_type": c["match_type"],
                    "rerank_score": round(score, 4),
                    "initial_score": round(c["initial_score"], 4),
                    "direct_hit": is_direct,
                    "keyword_hits": kw_hits,
                }
            )

        ranked.sort(key=lambda x: x["rerank_score"], reverse=True)
        return ranked

    def _load_results(self, top_ids, ranked_data, query_tokens=None, max_content_chars=DEFAULT_MAX_CONTENT_CHARS, max_total_chars=DEFAULT_MAX_TOTAL_CHARS, compact=True) -> List[SearchResult]:
        lookup = {r["doc_id"]: r for r in ranked_data}
        results = []
        total_chars = 0

        for doc_id in top_ids:
            r = lookup.get(doc_id)
            if not r:
                continue
            info = r["doc_info"]
            full_path = os.path.join(self.knowledge_dir, info["path"])
            content = ""
            if os.path.exists(full_path):
                with open(full_path, "r", encoding="utf-8") as fh:
                    content = fh.read()

            if compact:
                content = self._extract_compact(content, query_tokens or [], max_content_chars)
            else:
                content = self._extract_relevant_section(content, max_content_chars)

            remaining = max_total_chars - total_chars
            if remaining <= 0:
                break
            if len(content) > remaining:
                content = content[:remaining]

            total_chars += len(content)

            results.append(
                SearchResult(
                    id=doc_id,
                    content=content,
                    score=r["rerank_score"],
                    source=info["path"],
                    title=info.get("title", ""),
                    category=info.get("category", ""),
                    metadata={
                        "match_type": r["match_type"],
                        "rerank_score": r["rerank_score"],
                        "base_score": r["initial_score"],
                        "direct_hit": r["direct_hit"],
                        "keyword_hits": r["keyword_hits"],
                    },
                )
            )

        return results

    def _extract_compact(self, content: str, query_tokens: List[str], max_chars: int) -> str:
        if len(content) <= max_chars:
            return content

        sections = self._split_sections(content)

        code_blocks = []
        for title, body in sections:
            for cb in re.findall(r"```.*?```", body, re.DOTALL):
                code_blocks.append(cb)

        header = ""
        for line in content.split("\n"):
            if line.startswith("# "):
                header = line
            elif line.strip() and not line.startswith("#") and not line.startswith(">") and not line.startswith("|") and not line.startswith("-") and not line.startswith("[") and header:
                header += "\n" + line
                break

        api_sigs = []
        for title, body in sections:
            if "接口" in title or "Interface" in title or "interface" in title.lower():
                table_lines = []
                for line in body.split("\n"):
                    if line.startswith("|") and line.count("|") >= 3:
                        table_lines.append(line)
                if table_lines:
                    api_sigs.append("\n".join(table_lines))
                for sig in re.findall(r'\w+\([^)]*\)\s*(?::\s*[^{\n]+)?', body):
                    if len(sig) > 10:
                        api_sigs.append(sig)

        result_parts = []
        budget = max_chars

        if header:
            header_text = header[:min(len(header), budget // 5)]
            result_parts.append(header_text)
            budget -= len(header_text)

        for cb in code_blocks:
            if budget <= 0:
                break
            if len(cb) <= budget:
                result_parts.append(cb)
                budget -= len(cb)
            else:
                truncated = cb[:budget - 3] + "```"
                result_parts.append(truncated)
                budget = 0

        for sig in api_sigs[:3]:
            if budget <= 0:
                break
            if len(sig) <= budget:
                result_parts.append(sig)
                budget -= len(sig)

        result = "\n\n".join(result_parts)
        if len(result) > max_chars:
            result = result[:max_chars]
        return result

    def _extract_relevant_section(self, content: str, max_chars: int) -> str:
        if len(content) <= max_chars:
            return content

        sections = self._split_sections(content)
        code_sections = [s for s in sections if "```" in s[1]]
        non_code_sections = [s for s in sections if "```" not in s[1]]

        result_parts = []
        budget = max_chars

        if non_code_sections:
            first_part = non_code_sections[0][1]
            if len(first_part) <= budget:
                result_parts.append(first_part)
                budget -= len(first_part)
            else:
                result_parts.append(first_part[:budget])
                budget = 0

        for title, body in code_sections:
            if budget <= 0:
                break
            if len(body) <= budget:
                result_parts.append(body)
                budget -= len(body)
            else:
                code_blocks = re.findall(r"```[\s\S]*?```", body)
                for cb in code_blocks:
                    if len(cb) <= budget:
                        result_parts.append(cb)
                        budget -= len(cb)
                    else:
                        break

        result = "\n\n".join(result_parts) if result_parts else content[:max_chars]
        if len(result) > max_chars:
            result = result[:max_chars]
        return result

    def _extract_api_signature(self, body: str, budget: int) -> str:
        parts = []
        code_blocks = re.findall(r'```.*?```', body, re.DOTALL)
        for cb in code_blocks:
            if len(cb) <= budget:
                parts.append(cb)
                budget -= len(cb)

        table_rows = re.findall(r'\|[^|\n]+\|[^|\n]+\|[^|\n]+\|', body)
        for row in table_rows:
            if len(row) <= budget:
                parts.append(row)
                budget -= len(row)

        signatures = re.findall(r'\w+\([^)]*\)\s*(?::\s*\w+)?', body)
        for sig in signatures[:5]:
            if len(sig) <= budget:
                parts.append(sig)
                budget -= len(sig)

        return "\n".join(parts) if parts else ""

    def _split_sections(self, content: str) -> List[tuple]:
        sections = []
        current_title = ""
        current_body = []
        for line in content.split("\n"):
            if line.startswith("## ") or line.startswith("# "):
                if current_body:
                    sections.append((current_title, "\n".join(current_body)))
                current_title = line
                current_body = [line]
            else:
                current_body.append(line)
        if current_body:
            sections.append((current_title, "\n".join(current_body)))
        return sections

    def _apply_filters(self, results: List[SearchResult], filters: Dict) -> List[SearchResult]:
        out = []
        for r in results:
            if "category" in filters and r.category not in filters["category"]:
                continue
            out.append(r)
        return out

    def _build_context(self, results: List[SearchResult]) -> str:
        parts = []
        for i, r in enumerate(results, 1):
            parts.append(
                f"\n### [{i}] {r.title}\n"
                f"Source: {r.source}\n"
                f"Category: {r.category}\n"
                f"Relevance: {r.score:.2f}\n\n"
                f"{r.content}\n"
            )
        return "\n---\n".join(parts)

    def _extract_code_examples(self, results: List[SearchResult]) -> List[Dict]:
        examples = []
        for r in results:
            for block in self.code_extractor.extract_code_blocks(r.content)[:2]:
                examples.append(
                    {
                        "language": block["language"],
                        "code": block["code"],
                        "source": r.source,
                        "title": r.title,
                    }
                )
        return examples[:5]

    def _generate_suggestions(self, query: str, results: List[SearchResult]) -> List[str]:
        cats = set(r.category for r in results)
        suggestions = []
        if "02-state-management" in cats:
            suggestions.append("状态管理V1和V2有什么区别？")
        if "03-layout" in cats:
            suggestions.append("如何实现懒加载列表？")
        if "07-navigation" in cats:
            suggestions.append("Navigation和Router有什么区别？")
        suggestions += [
            f"{query}的最佳实践是什么？",
            f"{query}有性能优化建议吗？",
        ]
        return suggestions[:5]
