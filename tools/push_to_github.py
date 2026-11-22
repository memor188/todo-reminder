#!/usr/bin/env python3
"""把本地 git 历史通过 GitHub REST API 复刻到远端仓库。

为什么不用 git push：
    本机到 github.com 的网络不通（CONNECT tunnel failed / 超时），
    但 api.github.com 是通的。所以只能走 Git Data API 逐个提交重建。

用法：
    1. 把 token 写进 .gh_token（已在 .gitignore 里）：
       "ghp_xxx" | Out-File -Encoding ascii -NoNewline E:\\todo-app\\.gh_token
    2. python tools/push_to_github.py
    3. 用完删掉 .gh_token

做三件事：
    - 建仓库（已存在则跳过）
    - 按 git 历史顺序，逐个 commit 建 tree + commit（保留时间、作者、message）
    - 建 tag（annotated 的连 message 一起保真）

不做什么：
    - 不推 reflog、不推 refs/original
    - 不动本地仓库
"""

import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN_FILE = os.path.join(ROOT, ".gh_token")

REPO_NAME = "todo-reminder"
REPO_DESC = (
    "带定时提醒的待办与课程表 App（Flutter + Android）。"
    "课程按周期规则排周网格，待办分事件型/任务型，支持 AI 对话录入与本地硬提醒。"
)
API = "https://api.github.com"


def read_token():
    if not os.path.exists(TOKEN_FILE):
        sys.exit(f"没找到 {TOKEN_FILE}，先把 token 写进去。")
    token = open(TOKEN_FILE, encoding="utf-8-sig").read().strip()
    if not token:
        sys.exit("token 文件是空的。")
    return token


def api(token, method, path, payload=None, expect=(200, 201), allow_404=False):
    url = API + path
    data = None
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "todo-app-push-script",
    }
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            body = response.read().decode("utf-8")
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:600]
        if error.code in expect:
            return json.loads(detail) if detail.strip().startswith("{") else {}
        # 空仓库查 ref 会返回 409 而不是 404，两者都当"还没有"处理
        if error.code in (404, 409) and allow_404:
            return None
        sys.exit(f"{method} {path} 失败：{error.code}\n{detail}")
    except urllib.error.URLError as error:
        sys.exit(f"{method} {path} 网络错误：{error.reason}")


def git(*args, binary=False):
    result = subprocess.run(
        ["git", *args], cwd=ROOT, capture_output=True,
        check=True, encoding=None if binary else "utf-8",
    )
    return result.stdout


def list_commits():
    """从旧到新，带作者信息和完整 message。"""
    raw = git(
        "log", "--reverse", "--topo-order",
        "--format=%H%x1f%aI%x1f%an%x1f%ae%x1f%B%x1e",
    )
    commits = []
    for chunk in raw.split("\x1e"):
        chunk = chunk.strip("\n")
        if not chunk:
            continue
        sha, date, name, email, message = chunk.split("\x1f", 4)
        commits.append({
            "sha": sha,
            "date": date,
            "name": name,
            "email": email,
            "message": message.rstrip("\n"),
        })
    return commits


def tree_entries(token, owner, repo, sha, blob_cache):
    """一个提交的完整文件列表。文本内联 content，二进制走 blob。

    blob_cache：本地 blob sha → 远端 blob sha。同一张 png 会在十几个提交里
    反复出现，缓存住就不用重复上传。
    """
    listing = git("ls-tree", "-r", "-z", sha)
    entries = []
    for record in listing.split("\x00"):
        if not record.strip():
            continue
        meta, path = record.split("\t", 1)
        mode, kind, blob_sha = meta.split()
        if kind != "blob":
            continue
        content = git("cat-file", "blob", blob_sha, binary=True)
        try:
            text = content.decode("utf-8")
            entries.append({
                "path": path, "mode": mode, "type": "blob", "content": text,
            })
        except UnicodeDecodeError:
            remote_sha = blob_cache.get(blob_sha)
            if remote_sha is None:
                blob = api(token, "POST", f"/repos/{owner}/{repo}/git/blobs", {
                    "content": base64.b64encode(content).decode("ascii"),
                    "encoding": "base64",
                })
                remote_sha = blob["sha"]
                blob_cache[blob_sha] = remote_sha
            entries.append({
                "path": path, "mode": mode, "type": "blob", "sha": remote_sha,
            })
    return entries


def list_tags():
    """annotated tag 连 message 一起拿，lightweight 的只拿指向。

    ⚠️ annotated tag 的 %(objectname) 是 **tag 对象自身** 的 sha，不是它指向的
    提交；必须用 %(*objectname) 解引用，否则后面在 sha_map 里查不到，tag 会被跳过。
    """
    raw = git(
        "for-each-ref", "refs/tags",
        "--format=%(refname:short)%1f%(objecttype)%1f%(objectname)%1f%(*objectname)",
    )
    tags = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = line.split("\x1f")
        name, kind, obj = parts[0], parts[1], parts[2]
        deref = parts[3] if len(parts) > 3 else ""
        target = deref.strip() or obj
        tags.append({"name": name, "kind": kind, "target": target})
    return tags


def upsert_ref(token, owner, repo, ref, sha):
    """ref 存在就改指向，不存在就新建。

    空仓库会被 bootstrap 塞进一个占位提交，main 已存在，所以后面统一走这里。
    """
    existing = api(token, "GET", f"/repos/{owner}/{repo}/git/ref/{ref}", allow_404=True)
    if existing:
        api(token, "PATCH", f"/repos/{owner}/{repo}/git/refs/{ref}", {
            "sha": sha, "force": True,
        })
    else:
        api(token, "POST", f"/repos/{owner}/{repo}/git/refs", {
            "ref": f"refs/{ref}", "sha": sha,
        })


def bootstrap(token, owner, repo):
    """空仓库不能直接建 tree（POST /git/trees 返回 409 Git Repository is empty）。

    先塞一个文件把它变成非空仓库。这个占位提交最后会被悬空掉——main 会指向
    重建出来的第一个提交，占位提交不在任何分支的可达历史里。
    """
    api(token, "PUT", f"/repos/{owner}/{repo}/contents/.bootstrap", {
        "message": "bootstrap placeholder",
        "content": base64.b64encode(b"placeholder").decode("ascii"),
    })


def push_tags(token, owner, repo, sha_map):
    """sha_map 是 本地提交 sha → 远端提交 sha。

    查作者、tag message 这些信息必须用 **本地** sha（历史被 filter-branch
    重写过，两边 sha 完全不同）。
    """
    for tag in list_tags():
        local_sha = tag["target"]
        target = sha_map.get(local_sha)
        if target is None:
            print(f"  跳过 tag {tag['name']}（指向的提交不在本次历史里）")
            continue
        if tag["kind"] == "tag":
            message = git("tag", "-l", "--format=%(contents)", tag["name"]).strip()
            meta = git(
                "for-each-ref", f"refs/tags/{tag['name']}",
                "--format=%(taggername)%1f%(taggeremail)%1f%(taggerdate:iso-strict)",
            ).strip()
            parts = meta.split("\x1f")
            tagger_name = parts[0].strip() if len(parts) > 0 else ""
            tagger_email = parts[1].strip().strip("<>") if len(parts) > 1 else ""
            tagger_date = parts[2].strip() if len(parts) > 2 else ""
            tag_obj = api(token, "POST", f"/repos/{owner}/{repo}/git/tags", {
                "tag": tag["name"],
                "message": message or tag["name"],
                "object": target,
                "type": "commit",
                "tagger": {
                    "name": tagger_name or git(
                        "log", "-1", "--format=%an", local_sha).strip(),
                    "email": tagger_email or git(
                        "log", "-1", "--format=%ae", local_sha).strip(),
                    "date": tagger_date or "2026-11-22T00:00:00+08:00",
                },
            })
            sha = tag_obj["sha"]
        else:
            sha = target
        upsert_ref(token, owner, repo, f"tags/{tag['name']}", sha)
        print(f"  已建 tag {tag['name']}")


def tags_only(token, owner, repo):
    """提交已经推过，只把 tag 补上。

    远端提交列表和本地 rev-list 都是新→旧，按位置一一对应地建映射，
    避免为了补几个 tag 把 18 个提交再建一遍（那会留下一堆悬空对象）。
    """
    remote = api(token, "GET", f"/repos/{owner}/{repo}/commits?sha=main&per_page=100")
    local = git("rev-list", "HEAD").split()
    if len(remote) != len(local):
        sys.exit(f"提交数对不上（远端 {len(remote)} / 本地 {len(local)}），不敢只补 tag")
    sha_map = {l: r["sha"] for l, r in zip(local, remote)}
    push_tags(token, owner, repo, sha_map)


def append_commits(token, owner, repo):
    """只把本地多出来的提交追加到远端。

    远端的提交是重建出来的，sha 和本地完全不同，没法靠 sha 对齐。
    但 tree 的 sha 由文件内容和路径决定——两边内容一致 tree 就一致，
    所以用 tree 逐位置比对来判断"远端是不是本地历史的前缀"。
    """
    remote = api(token, "GET", f"/repos/{owner}/{repo}/commits?sha=main&per_page=100")
    local = git("rev-list", "HEAD").split()
    if len(local) < len(remote):
        sys.exit(f"本地提交数({len(local)})比远端({len(remote)})少，不能用追加模式")

    for index, item in enumerate(remote):
        local_tree = git("rev-parse", f"{local[index]}^{{tree}}").strip()
        if local_tree != item["commit"]["tree"]["sha"]:
            sys.exit(f"第 {index + 1} 个提交的 tree 对不上，历史已分叉，不能用追加模式")

    pending = list(reversed(local[: len(local) - len(remote)]))
    if not pending:
        print("没有新提交要推")
        return

    meta = {item["sha"]: item for item in list_commits()}
    parent = remote[0]["sha"]
    blob_cache = {}
    print(f"要追加 {len(pending)} 个提交")
    for index, sha in enumerate(pending, 1):
        item = meta[sha]
        entries = tree_entries(token, owner, repo, sha, blob_cache)
        tree = api(token, "POST", f"/repos/{owner}/{repo}/git/trees", {"tree": entries})
        commit = api(token, "POST", f"/repos/{owner}/{repo}/git/commits", {
            "message": item["message"],
            "tree": tree["sha"],
            "parents": [parent],
            "author": {
                "name": item["name"], "email": item["email"], "date": item["date"],
            },
            "committer": {
                "name": item["name"], "email": item["email"], "date": item["date"],
            },
        })
        parent = commit["sha"]
        print(f"  [{index}/{len(pending)}] {item['message'].splitlines()[0][:50]}")

    upsert_ref(token, owner, repo, "heads/main", parent)
    print("main 已更新")


def main():
    token = read_token()
    user = api(token, "GET", "/user")
    owner = user["login"]
    print(f"账号：{owner}")

    # 1. 仓库
    repo = api(token, "GET", f"/repos/{owner}/{REPO_NAME}", allow_404=True)
    if repo:
        print(f"仓库已存在：{repo['full_name']}")
    else:
        repo = api(token, "POST", "/user/repos", {
            "name": REPO_NAME,
            "description": REPO_DESC,
            "private": False,
            "auto_init": False,
        })
        print(f"仓库已创建：{repo['html_url']}")
    repo_name = repo["name"]

    # 只补 tag：提交已经推过时不必重建 18 个提交（会留下悬空对象）
    if "--tags-only" in sys.argv:
        print("只补 tag 模式")
        tags_only(token, owner, repo_name)
        print(f"\n完成：https://github.com/{owner}/{repo_name}")
        return

    if "--append" in sys.argv:
        print("追加模式")
        append_commits(token, owner, repo_name)
        print(f"\n完成：https://github.com/{owner}/{repo_name}")
        return

    # 空仓库不能直接建 tree（POST /git/trees 返回 409），先塞个占位提交
    has_main = api(token, "GET",
                   f"/repos/{owner}/{repo_name}/git/ref/heads/main", allow_404=True)
    if has_main is None:
        bootstrap(token, owner, repo_name)
        print("已放占位提交（空仓库不能直接建 tree）")

    # 2. 逐个提交重建（保留原始时间、作者、message）
    commits = list_commits()
    print(f"共 {len(commits)} 个提交要重建")
    sha_map = {}
    blob_cache = {}
    parent = None
    for index, item in enumerate(commits, 1):
        entries = tree_entries(token, owner, repo_name, item["sha"], blob_cache)
        tree = api(token, "POST", f"/repos/{owner}/{repo_name}/git/trees", {
            "tree": entries,
        })
        payload = {
            "message": item["message"],
            "tree": tree["sha"],
            "author": {
                "name": item["name"], "email": item["email"], "date": item["date"],
            },
            "committer": {
                "name": item["name"], "email": item["email"], "date": item["date"],
            },
        }
        if parent:
            payload["parents"] = [parent]
        commit = api(token, "POST", f"/repos/{owner}/{repo_name}/git/commits", payload)
        sha_map[item["sha"]] = commit["sha"]
        parent = commit["sha"]
        print(f"  [{index}/{len(commits)}] {item['message'].splitlines()[0][:50]}")

    # 3. main 指向最后一个提交
    upsert_ref(token, owner, repo_name, "heads/main", parent)
    print("已建分支 main")

    # 4. tag
    push_tags(token, owner, repo_name, sha_map)

    print(f"\n完成：https://github.com/{owner}/{repo_name}")


if __name__ == "__main__":
    main()
