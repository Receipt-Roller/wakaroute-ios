#!/usr/bin/env python3
"""Turn the understanding map into 理解要素 payloads for the AI 学習基盤.

Reads the prerequisite graph that ships with the app and writes the request
bodies for `/api/v1/organizations/{org}/concepts`. Validates first: a graph that
is wrong here becomes wrong for every client that reads it back.

Contract: LMS-DEV wiki「AI学習基盤 — 共通契約 v1」(concepts.v1).
"""

import argparse
import json
import sys
from pathlib import Path

GRAPH = Path(__file__).resolve().parents[2] / (
    "WakaRouteKit/Sources/WakaRouteKit/Content/../Resources/prerequisites-math.json"
)

EXTERNAL_SOURCE = "wakaroute"
SUBJECT = "数学"

# Domain code → the slug used in the concept Code, and the 領域 name.
#
# The slugs match the domain ids the study-cards API already uses
# (numbers / geometry / functions / data), so the two systems name the same
# 領域 the same way.
DOMAINS = {
    "A": ("numbers", "数と式"),
    "B": ("geometry", "図形"),
    "C": ("functions", "関数"),
    "D": ("data", "データの活用"),
}

# Element title → the ASCII slug used in its Code. Written out rather than
# transliterated, so the codes are stable and readable; a transliterator would
# quietly change them when it changed.
SLUGS = {
    "正の数・負の数": "signed-numbers",
    "文字を用いた式": "literal-expressions",
    "一次方程式": "linear-equations",
    "式の計算": "polynomial-arithmetic",
    "連立方程式": "simultaneous-equations",
    "平方根": "square-roots",
    "展開・因数分解": "expand-factorise",
    "二次方程式": "quadratic-equations",
    "平面図形・作図": "plane-figures",
    "空間図形": "solid-figures",
    "平行線と合同": "parallel-congruent",
    "三角形・四角形の証明": "triangle-quadrilateral-proof",
    "相似": "similarity",
    "円の性質": "circle-properties",
    "三平方の定理": "pythagorean-theorem",
    "変数と関数": "variables-functions",
    "比例・反比例": "proportion",
    "一次関数": "linear-functions",
    "一次関数の活用": "linear-functions-applied",
    "関数 y=ax²": "quadratic-functions",
    "いろいろな関数と活用": "other-functions",
    "データの分布": "data-distribution",
    "確率の意味": "probability-meaning",
    "四分位範囲・箱ひげ図": "quartiles-boxplot",
    "場合の数と確率": "counting-probability",
    "標本調査": "sampling",
}

# WakaRoute's five stages, as named in 共通契約 v1 §3.6 and in
# `UnderstandingMap.swift`. The platform holds the stage列; the thresholds
# themselves are still open (LMS-DEV t-d1bea158).
STAGES = [
    {"code": "meaning", "name": "意味がわかる", "description": "その要素が何の話かを説明できる。", "orderIndex": 1},
    {"code": "basic", "name": "基本を解ける", "description": "基本の問題を、手順どおりに解ける。", "orderIndex": 2},
    {"code": "connect", "name": "根拠をつなげる", "description": "なぜそうなるかを、前提とつないで説明できる。", "orderIndex": 3},
    {"code": "apply", "name": "初見で使える", "description": "はじめて見る問題でも、使い所を判断して使える。", "orderIndex": 4},
    {"code": "exam", "name": "時間内に安定する", "description": "入試と同じ時間の制約の中で、安定して正解できる。", "orderIndex": 5},
]

MAX_CODE = 64
MAX_NAME = 200
MAX_EXTERNAL_ID = 128


def load_graph(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def validate(graph):
    """Every problem, not just the first — a half-fixed graph is still broken."""
    problems = []
    elements = graph["elements"]
    by_course = {e["courseId"]: e for e in elements}

    if len(by_course) != len(elements):
        problems.append("courseId が重複しています。")

    for element in elements:
        title = element["title"]
        if title not in SLUGS:
            problems.append(f"slug が未定義: {title}")
        if element["domain"] not in DOMAINS:
            problems.append(f"領域コードが不明: {title} → {element['domain']}")
        if len(element["courseId"]) > MAX_EXTERNAL_ID:
            problems.append(f"courseId が長すぎます: {title}")
        if len(title) > MAX_NAME:
            problems.append(f"title が長すぎます: {title}")
        for required in element.get("requires", []):
            if required not in by_course:
                problems.append(f"存在しないコースを前提にしています: {title} ← {required}")

    codes = [concept_code(e) for e in elements if e["title"] in SLUGS and e["domain"] in DOMAINS]
    if len(set(codes)) != len(codes):
        problems.append("Code が重複しています。")
    for code in codes:
        if len(code) > MAX_CODE:
            problems.append(f"Code が長すぎます ({len(code)}): {code}")

    problems += find_cycles(by_course)
    return problems


def find_cycles(by_course):
    """A cycle is rejected by the server with a 400; better to say which one."""
    problems = []
    WHITE, GREY, BLACK = 0, 1, 2
    colour = {course: WHITE for course in by_course}

    def walk(course, trail):
        colour[course] = GREY
        for required in by_course[course].get("requires", []):
            if required not in by_course:
                continue
            if colour[required] == GREY:
                names = " → ".join(by_course[c]["title"] for c in trail + [required])
                problems.append(f"前提関係が循環しています: {names}")
            elif colour[required] == WHITE:
                walk(required, trail + [required])
        colour[course] = BLACK

    for course in by_course:
        if colour[course] == WHITE:
            walk(course, [course])
    return problems


def concept_code(element):
    domain_slug = DOMAINS[element["domain"]][0]
    return f"math.{domain_slug}.{SLUGS[element['title']]}"


def build(graph):
    elements = graph["elements"]
    order = {"A": 0, "B": 1, "C": 2, "D": 3}
    ordered = sorted(
        enumerate(elements),
        key=lambda pair: (order[pair[1]["domain"]], pair[1]["grade"], pair[0]),
    )

    concepts = []
    for index, (_, element) in enumerate(ordered, start=1):
        _, area = DOMAINS[element["domain"]]
        concepts.append({
            "code": concept_code(element),
            "name": element["title"],
            # Filled from MANABU2 at import time so it cannot go stale here.
            "description": None,
            "subject": SUBJECT,
            "area": area,
            "externalSource": EXTERNAL_SOURCE,
            "externalId": element["courseId"],
            "orderIndex": index,
            "isActive": True,
            # Not sent; used to resolve prerequisites after the ids come back.
            "_requires": list(element.get("requires", [])),
            "_grade": element["grade"],
        })

    return {
        "asOf": graph.get("asOf"),
        "subject": SUBJECT,
        "source": graph.get("source"),
        "stages": STAGES,
        "concepts": concepts,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graph", default=str(GRAPH))
    parser.add_argument("--out", default=str(Path(__file__).with_name("payloads.json")))
    arguments = parser.parse_args()

    graph = load_graph(arguments.graph)
    problems = validate(graph)
    if problems:
        print("検証に失敗しました。取り込みを中止します。\n", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    payloads = build(graph)
    Path(arguments.out).write_text(
        json.dumps(payloads, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    edges = sum(len(c["_requires"]) for c in payloads["concepts"])
    print(f"理解要素 {len(payloads['concepts'])} 件、前提 {edges} 本、段階 {len(STAGES)} 件")
    print(f"→ {arguments.out}")
    print("\n次: import_concepts.py で取り込みます（既定は dry-run）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
