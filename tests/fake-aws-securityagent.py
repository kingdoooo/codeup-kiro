#!/usr/bin/env python3
"""`aws securityagent <操作> --cli-input-json file://… --region … --output json` 的替身（tests/test-security.sh 的驱动用例用）。

行为照 issue 09 的 sandbox 实测，不照文档猜（spec「SA 探测结论」）：
  · UpdateCodeReview 整体替换 assets；带 sourceCode 时必须同时带 serviceRole（否则 ValidationException）；
  · StartCodeReviewJob 的 diffSource.s3Uri 必须以 .patch 结尾；作业在 Start 时**记下** code review 当时的 sourceCode
    （之后再重指向不影响它，J3b）；没有幂等令牌；
  · CreateCodeReview 必须 codeRemediationStrategy=DISABLED、validationMode=DISABLED（本项目的 I2；替身拒绝别的取值，好让测试看见）；
  · 并发上限：IN_PROGRESS 的作业达到 FAKE_SA_MAX_CONCURRENT（缺省 10）时 Start 报 ThrottlingException（不建作业）；
  · 作业终态以 status 为准：COMPLETED 时 steps 里 FINALIZING 可以仍是 NOT_STARTED（替身就这么给）。
状态存在 FAKE_SA_STATE（JSON），读改写持文件锁；每次调用追加一行到 FAKE_SA_LOG：`<操作> <请求 JSON>`。
出错形状照 AWS CLI v2：`An error occurred (<Code>) when calling the <Op> operation: …` 到 stderr、退出码 254。

场景开关（环境变量）：
  FAKE_SA_START_THROTTLE=<n>     前 n 次 Start 报 ThrottlingException（不建作业）
  FAKE_SA_START_AMBIGUOUS=1      第一次 Start 建了作业、却回 InternalServerException（应答丢失的形状）
  FAKE_SA_JOB_STATUSES=a,b,…     每次 BatchGetCodeReviewJobs 依次给出的状态（最后一个之后一直是它）；缺省 COMPLETED
  FAKE_SA_JOB_ERROR=<code>       作业 FAILED / STOPPED 时的 errorInformation.code
  FAKE_SA_JOB_SOURCE_OVERRIDE=<uri>  作业记下的 sourceCode 换成这个（模拟「读到了别人的源」）
  FAKE_SA_JOB_TEMPLATE=<文件>    BatchGetCodeReviewJobs 输出的模板（取其 codeReviewJobs[0] 的 overview）
  FAKE_SA_FINDINGS=<文件>        ListFindings / BatchGetFindings 的数据来源（一个 BatchGetFindings 输出）
  FAKE_SA_FAIL_<操作>=<Code>     该操作一律报这个错误码（操作名大写、去掉连字符，例如 FAKE_SA_FAIL_CREATECODEREVIEW）
"""
import fcntl
import json
import os
import sys

OPS = {
    "create-code-review": "CreateCodeReview", "update-code-review": "UpdateCodeReview",
    "list-code-reviews": "ListCodeReviews", "start-code-review-job": "StartCodeReviewJob",
    "stop-code-review-job": "StopCodeReviewJob", "batch-get-code-review-jobs": "BatchGetCodeReviewJobs",
    "list-code-review-jobs-for-code-review": "ListCodeReviewJobsForCodeReview",
    "list-findings": "ListFindings", "batch-get-findings": "BatchGetFindings",
}


class ApiError(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code, self.msg = code, msg


def die(msg):
    print(f"fake-aws-securityagent: {msg}", file=sys.stderr)
    sys.exit(2)


def parse(argv):
    if len(argv) < 2 or argv[0] != "securityagent" or argv[1] not in OPS:
        die(f"unsupported command: {argv[:2]}")
    opts, i = {}, 2
    while i < len(argv):
        if not argv[i].startswith("--") or i + 1 >= len(argv):
            die(f"bad argument {argv[i]!r}")
        opts[argv[i]] = argv[i + 1]
        i += 2
    if set(opts) - {"--region", "--cli-input-json", "--output"}:
        die(f"unexpected options {sorted(set(opts))}")
    src = opts.get("--cli-input-json", "")
    if not src.startswith("file://"):
        die("requests must come via --cli-input-json file://…")
    with open(src[len("file://"):]) as fh:
        return argv[1], json.load(fh)


def ts(n):
    return f"2026-10-08T01:00:{n:02d}.000000+00:00"


def need(req, *keys):
    for k in keys:
        if not req.get(k):
            raise ApiError("ValidationException", f"{k} is required")


def handle(op, req, st):
    st.setdefault("codeReviews", {}); st.setdefault("jobs", {}); st.setdefault("n", 0); st.setdefault("starts", 0)
    st.setdefault("polls", {})
    forced = os.environ.get("FAKE_SA_FAIL_" + OPS[op].upper())
    if forced:
        raise ApiError(forced, "injected")
    if op == "create-code-review":
        need(req, "agentSpaceId", "title", "assets")
        if req.get("codeRemediationStrategy") != "DISABLED" or req.get("validationMode") != "DISABLED":
            raise ApiError("ValidationException", "this fake only accepts DISABLED remediation and validation")
        if not req["assets"].get("sourceCode"):
            raise ApiError("ValidationException", "sourceCode required")
        st["n"] += 1
        cid = f"cr-{st['n']:08x}-0000-4000-8000-000000000000"
        st["codeReviews"][cid] = {"codeReviewId": cid, "title": req["title"], "assets": req["assets"],
                                  "serviceRole": req.get("serviceRole"), "agentSpaceId": req["agentSpaceId"],
                                  "createdAt": ts(st["n"])}
        return {"codeReviewId": cid, "title": req["title"]}
    if op == "list-code-reviews":
        need(req, "agentSpaceId")
        return {"codeReviewSummaries": [{"codeReviewId": c["codeReviewId"], "title": c["title"], "createdAt": c["createdAt"]}
                                        for c in st["codeReviews"].values() if c["agentSpaceId"] == req["agentSpaceId"]]}
    if op == "update-code-review":
        need(req, "agentSpaceId", "codeReviewId")
        cr = st["codeReviews"].get(req["codeReviewId"])
        if cr is None:
            raise ApiError("ResourceNotFoundException", "code review not found")
        if "assets" in req:
            if req["assets"].get("sourceCode") and not req.get("serviceRole"):
                raise ApiError("ValidationException", "Service role is required when source code is provided")
            cr["assets"] = req["assets"]
        if req.get("serviceRole"):
            cr["serviceRole"] = req["serviceRole"]
        return {"codeReviewId": cr["codeReviewId"], "assets": cr["assets"]}
    if op == "start-code-review-job":
        need(req, "agentSpaceId", "codeReviewId")
        st["starts"] += 1
        if st["starts"] <= int(os.environ.get("FAKE_SA_START_THROTTLE", "0")):
            raise ApiError("ThrottlingException", "Too many concurrent code review executions. Maximum allowed: 10")
        uri = (req.get("diffSource") or {}).get("s3Uri", "")
        if not uri.endswith(".patch"):
            raise ApiError("ValidationException", "diffSource.s3Uri must point to a .patch file.")
        cr = st["codeReviews"].get(req["codeReviewId"])
        if cr is None:
            raise ApiError("ResourceNotFoundException", "code review not found")
        running = [j for j in st["jobs"].values() if j["status"] == "IN_PROGRESS"]
        if len(running) >= int(os.environ.get("FAKE_SA_MAX_CONCURRENT", "10")):
            raise ApiError("ThrottlingException", "Too many concurrent code review executions. Maximum allowed: 10")
        st["n"] += 1
        jid = f"cj-{st['n']:08x}-0000-4000-8000-000000000000"
        src = cr["assets"]["sourceCode"]
        if os.environ.get("FAKE_SA_JOB_SOURCE_OVERRIDE"):
            src = [{"s3Location": os.environ["FAKE_SA_JOB_SOURCE_OVERRIDE"]}]
        st["jobs"][jid] = {"codeReviewJobId": jid, "codeReviewId": cr["codeReviewId"], "status": "IN_PROGRESS",
                           "sourceCode": json.loads(json.dumps(src)), "diffSource": uri, "createdAt": ts(st["n"])}
        if os.environ.get("FAKE_SA_START_AMBIGUOUS") and st["starts"] == 1:
            raise ApiError("InternalServerException", "Internal Server Error")
        return {"codeReviewJobId": jid, "codeReviewId": cr["codeReviewId"], "status": "IN_PROGRESS"}
    if op == "stop-code-review-job":
        need(req, "agentSpaceId", "codeReviewJobId")
        job = st["jobs"].get(req["codeReviewJobId"])
        if job is None:
            raise ApiError("ResourceNotFoundException", "job not found")
        job["status"] = "STOPPING"
        job["stopped"] = True
        return {}
    if op == "batch-get-code-review-jobs":
        need(req, "agentSpaceId", "codeReviewJobIds")
        seq = [s for s in os.environ.get("FAKE_SA_JOB_STATUSES", "COMPLETED").split(",") if s]
        tmpl = {}
        if os.environ.get("FAKE_SA_JOB_TEMPLATE"):
            with open(os.environ["FAKE_SA_JOB_TEMPLATE"]) as fh:
                tmpl = json.load(fh)["codeReviewJobs"][0]
        out, missing = [], []
        for jid in req["codeReviewJobIds"]:
            job = st["jobs"].get(jid)
            if job is None:
                missing.append(jid)
                continue
            if not job.get("stopped"):
                k = st["polls"].get(jid, 0)
                st["polls"][jid] = k + 1
                job["status"] = seq[min(k, len(seq) - 1)]
            rec = {**{k: v for k, v in tmpl.items() if k in ("overview", "title")}, **{k: v for k, v in job.items() if k != "stopped"}}
            rec["steps"] = [{"name": "PREFLIGHT", "status": "COMPLETED"}, {"name": "STATIC_ANALYSIS", "status": "COMPLETED"},
                            {"name": "FINALIZING", "status": "NOT_STARTED"}]
            if job["status"] in ("FAILED", "STOPPED", "STOPPING"):
                rec["errorInformation"] = {"code": os.environ.get("FAKE_SA_JOB_ERROR", "STOPPED_BY_USER"),
                                           "message": "s3://secret-bucket/secret-key failed"}
            out.append(rec)
        return {"codeReviewJobs": out, "notFound": missing}
    if op == "list-code-review-jobs-for-code-review":
        need(req, "agentSpaceId", "codeReviewId")
        return {"codeReviewJobSummaries": [
            {k: j[k] for k in ("codeReviewJobId", "codeReviewId", "status", "createdAt")}
            for j in st["jobs"].values() if j["codeReviewId"] == req["codeReviewId"]]}
    if op in ("list-findings", "batch-get-findings"):
        need(req, "agentSpaceId")
        data = {"findings": []}
        if os.environ.get("FAKE_SA_FINDINGS"):
            with open(os.environ["FAKE_SA_FINDINGS"]) as fh:
                data = json.load(fh)
        if op == "list-findings":
            need(req, "codeReviewJobId")
            if req["codeReviewJobId"] not in st["jobs"]:
                raise ApiError("ResourceNotFoundException", "job not found")
            return {"findingsSummaries": [{"findingId": f["findingId"], "riskLevel": f.get("riskLevel")} for f in data["findings"]]}
        need(req, "findingIds")
        want = set(req["findingIds"])
        return {"findings": [f for f in data["findings"] if f["findingId"] in want], "notFound": []}
    die(f"unhandled {op}")


def main():
    op, req = parse(sys.argv[1:])
    state_path = os.environ["FAKE_SA_STATE"]
    log_path = os.environ.get("FAKE_SA_LOG")
    with open(state_path + ".lock", "a+") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            with open(state_path) as fh:
                st = json.load(fh)
        except FileNotFoundError:
            st = {}
        err = None
        try:
            resp = handle(op, req, st)
        except ApiError as e:
            err = e
        with open(state_path + ".tmp", "w") as fh:
            json.dump(st, fh)
        os.replace(state_path + ".tmp", state_path)
        if log_path:
            with open(log_path, "a") as fh:
                fh.write(f"{op} {json.dumps(req, sort_keys=True, ensure_ascii=False)} {'ERR ' + err.code if err else 'ok'}"
                         f" attempts={os.environ.get('AWS_MAX_ATTEMPTS', '-')}\n")
    if err:
        print(f"\nAn error occurred ({err.code}) when calling the {OPS[op]} operation: {err.msg}", file=sys.stderr)
        sys.exit(254)
    print(json.dumps(resp))


if __name__ == "__main__":
    main()
