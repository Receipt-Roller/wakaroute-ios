#!/usr/bin/env python3
"""Load the 理解要素 into the AI 学習基盤.

Dry run unless --apply is given. Safe to run again: concepts are matched on
Code, and prerequisites and stages are full replacements, so a second run
changes nothing.

Order matters. Every concept must exist before any prerequisite can point at
it, so the two passes are separate.

  1. concepts      POST /concepts   (or PUT when the Code already exists)
  2. prerequisites PUT  /concepts/{id}/prerequisites
  3. stages        PUT  /concepts/stages

Needs a token with `write:content` belonging to a curriculum manager or admin
of the organization. A device token cannot do this.

  export MANABU2_TOKEN=...
  python3 import_concepts.py --org a461577a-3410-4c98-b1d5-db729f3444a1
  python3 import_concepts.py --org ... --apply
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

BASE = "https://api.manabu2.com"
PAYLOADS = Path(__file__).with_name("payloads.json")


class Api:
    def __init__(self, token, base=BASE, dry_run=True):
        self.token = token
        self.base = base
        self.dry_run = dry_run

    def get(self, path):
        return self._send("GET", path, None)

    def post(self, path, body):
        if self.dry_run:
            return {"_dryRun": True}
        return self._send("POST", path, body)

    def put(self, path, body):
        if self.dry_run:
            return {"_dryRun": True}
        return self._send("PUT", path, body)

    def _send(self, method, path, body):
        request = urllib.request.Request(
            self.base + path,
            method=method,
            data=json.dumps(body).encode("utf-8") if body is not None else None,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/json",
                **({"Content-Type": "application/json"} if body is not None else {}),
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                text = response.read().decode("utf-8")
                return json.loads(text) if text else {}
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")
            hint = ""
            if error.code in (401, 403):
                hint = ("\nトークンを確認してください。write:content を持つ、その組織の"
                        "カリキュラム管理者か管理者のトークンが要ります。"
                        "端末トークンでは書き込めません。")
            raise SystemExit(f"{method} {path} → {error.code}{hint}\n{detail}") from error
        except urllib.error.URLError as error:
            raise SystemExit(f"{method} {path} に接続できません: {error.reason}") from error


def course_description(api, course_id, cache):
    """The 要素's description, taken from the course itself.

    Kept out of the repository on purpose: a copy here would drift from what
    the content team actually wrote.
    """
    if course_id in cache:
        return cache[course_id]
    try:
        course = api.get(f"/api/v1/courses/{course_id}")
        cache[course_id] = (course.get("description") or "").strip()
    except SystemExit:
        cache[course_id] = ""
    return cache[course_id]


def existing_concepts(api, org):
    listing = api.get(f"/api/v1/organizations/{org}/concepts?includeInactive=true")
    items = listing if isinstance(listing, list) else listing.get("items", [])
    return {item["code"]: item for item in items if item.get("code")}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--org", required=True, help="組織ID")
    parser.add_argument("--payloads", default=str(PAYLOADS))
    parser.add_argument("--base", default=BASE)
    parser.add_argument("--apply", action="store_true", help="実際に書き込む（既定は dry-run）")
    parser.add_argument("--skip-descriptions", action="store_true",
                        help="コース説明を取得しない（説明は空のまま）")
    arguments = parser.parse_args()

    token = os.environ.get("MANABU2_TOKEN")
    if not token:
        raise SystemExit("MANABU2_TOKEN が設定されていません。write:content を持つトークンが要ります。")

    payloads = json.loads(Path(arguments.payloads).read_text(encoding="utf-8"))
    api = Api(token, base=arguments.base, dry_run=not arguments.apply)

    mode = "APPLY" if arguments.apply else "DRY RUN（何も書き込みません）"
    print(f"=== {mode} ===")
    print(f"組織 {arguments.org} / 元データ基準日 {payloads.get('asOf')}\n")

    print("既存の理解要素を確認しています…")
    existing = existing_concepts(api, arguments.org)
    print(f"  既存 {len(existing)} 件\n")

    descriptions = {}
    created = updated = unchanged = 0
    ids_by_course = {}

    print("--- 1. 理解要素 ---")
    for concept in payloads["concepts"]:
        body = {k: v for k, v in concept.items() if not k.startswith("_")}
        if not arguments.skip_descriptions:
            body["description"] = course_description(api, concept["externalId"], descriptions)

        current = existing.get(concept["code"])
        if current is None:
            result = api.post(f"/api/v1/organizations/{arguments.org}/concepts", body)
            ids_by_course[concept["externalId"]] = result.get("id", f"<new:{concept['code']}>")
            created += 1
            print(f"  + {concept['code']:<46} {concept['name']}")
        else:
            ids_by_course[concept["externalId"]] = current["id"]
            differs = any(current.get(key) != value for key, value in body.items()
                          if key in current and key != "description")
            if differs:
                api.put(f"/api/v1/organizations/{arguments.org}/concepts/{current['id']}", body)
                updated += 1
                print(f"  ~ {concept['code']:<46} {concept['name']}")
            else:
                unchanged += 1

    print(f"\n  新規 {created} / 更新 {updated} / 変更なし {unchanged}\n")

    print("--- 2. 前提関係 ---")
    edges = 0
    for concept in payloads["concepts"]:
        requires = concept["_requires"]
        if not requires:
            continue
        concept_id = ids_by_course[concept["externalId"]]
        # Every edge in this graph means「これが固まっていないと身につかない」.
        body = [{"conceptId": ids_by_course[course], "strength": "required"} for course in requires]
        api.put(f"/api/v1/organizations/{arguments.org}/concepts/{concept_id}/prerequisites", body)
        edges += len(body)
        names = "、".join(
            next(c["name"] for c in payloads["concepts"] if c["externalId"] == course)
            for course in requires
        )
        print(f"  {concept['name']:<22} ← {names}")
    print(f"\n  前提 {edges} 本\n")

    print("--- 3. 習得段階 ---")
    api.put(f"/api/v1/organizations/{arguments.org}/concepts/stages", payloads["stages"])
    for stage in payloads["stages"]:
        print(f"  {stage['orderIndex']}. {stage['code']:<8} {stage['name']}")

    if not arguments.apply:
        print("\n何も書き込んでいません。実行するには --apply を付けてください。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
