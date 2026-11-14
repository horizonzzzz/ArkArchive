"""以紧凑的数值数组格式保存可读的特效描述。"""

import json
import re


_NUMBER_ARRAY = re.compile(
    r'\[\s*(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?'
    r'(?:\s*,\s*-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)*)\s*\]'
)


def dumps(data):
    text = json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False)
    return _NUMBER_ARRAY.sub(lambda match: '[' + ' '.join(match.group(1).split()) + ']', text) + '\n'
