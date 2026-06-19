"""
ArkUI Document Utilities
"""

import re
from typing import List, Dict


class CodeExtractor:
    """Extract code blocks from documents"""

    def extract_code_blocks(self, content: str) -> List[Dict]:
        pattern = r"```(\w+)?\n(.*?)\n```"
        matches = re.findall(pattern, content, re.DOTALL)
        return [
            {"language": lang or "unknown", "code": code.strip(), "index": i}
            for i, (lang, code) in enumerate(matches)
        ]
