#!/usr/bin/env python3
"""
ArkTS Document Search Tool

Search ArkTS language guide documents using keyword matching and topic aliases.
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple


class ArkTSSearcher:
    def __init__(self, references_dir: str):
        self.references_dir = Path(references_dir)
        self.doc_index: Dict = {}
        self.snippet_index: Dict = {}
        self.topic_aliases: Dict = {}
        self._load_indexes()

    def _load_indexes(self) -> None:
        """Load all index files."""
        doc_index_path = self.references_dir / "doc_index.json"
        snippet_index_path = self.references_dir / "snippet_index.json"
        aliases_path = self.references_dir / "topic_aliases.json"

        if doc_index_path.exists():
            with open(doc_index_path, 'r', encoding='utf-8') as f:
                self.doc_index = json.load(f)

        if snippet_index_path.exists():
            with open(snippet_index_path, 'r', encoding='utf-8') as f:
                self.snippet_index = json.load(f)

        if aliases_path.exists():
            with open(aliases_path, 'r', encoding='utf-8') as f:
                self.topic_aliases = json.load(f)

    def _expand_query(self, query: str) -> List[str]:
        """Expand query using topic aliases."""
        expanded = [query.lower()]
        aliases = self.topic_aliases.get("aliases", {})

        for key, values in aliases.items():
            if key.lower() in query.lower():
                expanded.extend([v.lower() for v in values])
            for value in values:
                if value.lower() in query.lower():
                    expanded.append(key.lower())
                    expanded.extend([v.lower() for v in values])

        return list(set(expanded))

    def _calculate_relevance(self, doc: Dict, query_terms: List[str]) -> float:
        """Calculate relevance score for a document."""
        score = 0.0
        title = doc.get("title", "").lower()
        keywords = [k.lower() for k in doc.get("keywords", [])]
        sections = [s.lower() for s in doc.get("sections", [])]

        for term in query_terms:
            if term in title:
                score += 3.0
            if term in keywords:
                score += 2.0
            if term in " ".join(sections):
                score += 1.0

        if doc.get("verification_level") == "snippet_validated":
            score += 0.5

        return score

    def search(
        self,
        query: str,
        scope: Optional[str] = None,
        top_k: int = 5
    ) -> List[Dict]:
        """Search documents matching the query."""
        query_terms = self._expand_query(query)
        documents = self.doc_index.get("documents", [])
        results = []

        for doc in documents:
            if scope:
                doc_path = doc.get("path", "")
                if scope not in doc_path:
                    continue

            score = self._calculate_relevance(doc, query_terms)
            if score > 0:
                results.append({
                    "path": doc.get("path", ""),
                    "title": doc.get("title", ""),
                    "sections": doc.get("sections", []),
                    "keywords": doc.get("keywords", []),
                    "verification_level": doc.get("verification_level", "doc_only"),
                    "score": score
                })

        results.sort(key=lambda x: x["score"], reverse=True)
        return results[:top_k]

    def format_result(self, result: Dict, index: int) -> str:
        """Format a single search result."""
        output = []
        output.append(f"\n{index}. 📚 **参考文档**: {result['title']}")
        output.append(f"   📍 **路径**: references/{result['path']}")
        output.append(f"   📖 **章节**: {', '.join(result['sections'][:3])}")
        output.append(f"   🔑 **关键词**: {', '.join(result['keywords'][:5])}")
        output.append(f"   ✅ **验证状态**: {result['verification_level']}")
        output.append(f"   📊 **相关度**: {result['score']:.1f}")
        return "\n".join(output)

    def format_results(self, results: List[Dict], query: str) -> str:
        """Format all search results."""
        if not results:
            return f"❌ 未找到与 '{query}' 相关的文档。\n\n建议：\n1. 尝试使用更通用的关键词\n2. 使用英文关键词\n3. 查看主题别名映射"

        output = [f"🔍 检索结果: '{query}'"]
        output.append(f"找到 {len(results)} 个相关文档:\n")

        for i, result in enumerate(results, 1):
            output.append(self.format_result(result, i))

        return "\n".join(output)


def main():
    parser = argparse.ArgumentParser(
        description="Search ArkTS language guide documents"
    )
    parser.add_argument(
        "--query", "-q",
        required=True,
        help="Search query string"
    )
    parser.add_argument(
        "--scope", "-s",
        help="Limit search scope (e.g., '02-Basic-Syntax')"
    )
    parser.add_argument(
        "--top-k", "-k",
        type=int,
        default=5,
        help="Number of results to return (default: 5)"
    )
    parser.add_argument(
        "--references-dir", "-r",
        default=None,
        help="Path to references directory"
    )

    args = parser.parse_args()

    if args.references_dir:
        references_dir = args.references_dir
    else:
        script_dir = Path(__file__).parent
        references_dir = script_dir.parent / "references"

    searcher = ArkTSSearcher(references_dir)
    results = searcher.search(args.query, args.scope, args.top_k)
    print(searcher.format_results(results, args.query))


if __name__ == "__main__":
    main()
