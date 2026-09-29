#!/usr/bin/env python3
"""`aws dynamodb update-item / get-item` 的替身，给 tests/test-aws-entrypoint.sh 的租约断言用。

它**真的求值**条件表达式与更新表达式（只支持 entrypoint 用到的那一小片语法），而不是认出几句
写死的字符串：删掉条件、把条件改弱，这里就真的照写，测试才看得见重叠。认不出的语法一律
退出 2 并报错，不猜——认不出就放行会让变异测试假绿。

状态存在 FAKE_DDB_STATE 指向的 JSON 文件里（pk → 属性字典，属性值保持 DynamoDB 的
{"S": …} / {"N": …} / {"BOOL": …} 形状），读改写全程持文件锁，两个并发的 entrypoint 看到的是
同一张表。每次调用追加一行到 FAKE_DDB_LOG（操作名 + pk + 结果），供断言请求形状。

出错形状照 AWS CLI v2：服务端错误打 `An error occurred (<Code>) when calling the <Op> operation: …`
到 stderr、退出码 254。FAKE_DDB_FAIL=<操作名> 让该操作一律报 ProvisionedThroughputExceededException；再设
FAKE_DDB_FAIL_KIND=connect 则改成「连不上端点」（没有错误码的那种）。
FAKE_DDB_FAIL_NTH=<n> 只让第 n 次 update-item 报限流（租约续期「失败一次后接着续」用）。更新表达式支持 `SET …` 与可选的 `REMOVE …`。
FAKE_DDB_EMPTY_GET=blank 时查不到记录打空输出（默认打 `{}`）——两种都要能被 entrypoint 读成「不存在」。
"""
import fcntl
import json
import os
import re
import sys

OPS = {"update-item": "UpdateItem", "get-item": "GetItem"}


def die(msg):
    print(f"fake-aws-dynamodb: {msg}", file=sys.stderr)
    sys.exit(2)


def service_error(op, code, text):
    print(f"\nAn error occurred ({code}) when calling the {OPS[op]} operation: {text}",
          file=sys.stderr)
    sys.exit(254)


def parse_args(argv):
    if len(argv) < 2 or argv[0] != "dynamodb" or argv[1] not in OPS:
        die(f"unsupported command: {argv[:2]}")
    opts, i = {}, 2
    while i < len(argv):
        a = argv[i]
        if not a.startswith("--"):
            die(f"unexpected positional {a!r}")
        if a == "--consistent-read":
            opts[a] = True
            i += 1
            continue
        if i + 1 >= len(argv):
            die(f"{a} needs a value")
        opts[a] = argv[i + 1]
        i += 2
    return argv[1], opts


TOKEN = re.compile(r"\s*(attribute_not_exists|attribute_exists|AND|OR|<>|<=|>=|[()<>=,]"
                   r"|#[A-Za-z0-9_]+|:[A-Za-z0-9_]+|[A-Za-z_][A-Za-z0-9_]*)")


def tokens(expr):
    out, pos = [], 0
    while pos < len(expr):
        if expr[pos:].strip() == "":
            break
        m = TOKEN.match(expr, pos)
        if not m:
            die(f"cannot tokenise {expr!r} at {pos}")
        out.append(m.group(1))
        pos = m.end()
    return out


class Cond:
    """递归下降：expr := term (OR term)* ; term := factor (AND factor)* ;
    factor := fn(name) | operand op operand | ( expr )"""

    def __init__(self, toks, names, values, item):
        self.t, self.i = toks, 0
        self.names, self.values, self.item = names, values, item

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else None

    def take(self, want=None):
        tok = self.peek()
        if tok is None or (want is not None and tok != want):
            die(f"expected {want!r}, got {tok!r} in {' '.join(self.t)}")
        self.i += 1
        return tok

    def name(self, tok):
        if tok.startswith("#"):
            if tok not in self.names:
                die(f"undefined attribute name {tok}")
            return self.names[tok]
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", tok) and tok not in ("AND", "OR"):
            return tok
        die(f"not an attribute name: {tok!r}")

    def operand(self):
        tok = self.take()
        if tok.startswith(":"):
            if tok not in self.values:
                die(f"undefined value {tok}")
            return self.values[tok]
        return self.item.get(self.name(tok))

    def parse(self):
        v = self.expr()
        if self.peek() is not None:
            die(f"trailing tokens in condition: {self.t[self.i:]}")
        return v

    def expr(self):
        v = self.term()
        while self.peek() == "OR":
            self.take()
            v = self.term() or v
        return v

    def term(self):
        v = self.factor()
        while self.peek() == "AND":
            self.take()
            v = self.factor() and v
        return v

    def factor(self):
        tok = self.peek()
        if tok == "(":
            self.take()
            v = self.expr()
            self.take(")")
            return v
        if tok in ("attribute_not_exists", "attribute_exists"):
            self.take()
            self.take("(")
            attr = self.name(self.take())
            self.take(")")
            present = attr in self.item
            return present if tok == "attribute_exists" else not present
        left = self.operand()
        op = self.take()
        if op not in ("=", "<>", "<", ">", "<=", ">="):
            die(f"unsupported operator {op!r}")
        right = self.operand()
        return compare(left, op, right)


def compare(a, op, b):
    # DynamoDB：属性不存在或类型不同，比较一律为假（<> 也一样按「无法比较」处理）
    if a is None or b is None or set(a) != set(b):
        return False
    (typ,) = a
    x, y = a[typ], b[typ]
    if typ == "N":
        x, y = int(x), int(y)
    return {"=": x == y, "<>": x != y, "<": x < y, ">": x > y, "<=": x <= y, ">=": x >= y}[op]


def apply_update(expr, names, values, item):
    # `SET a = :x, b = :y` 可选跟一个 `REMOVE #c[, #d]`（租约释放用它抹掉持有者，issue 04）
    m = re.fullmatch(r"\s*SET\s+(.+?)(?:\s+REMOVE\s+(.+))?\s*", expr)
    if not m:
        die(f"only SET [REMOVE] updates are supported: {expr!r}")
    for part in (m.group(2) or "").split(",") if m.group(2) else []:
        rm = re.fullmatch(r"\s*(#?[A-Za-z0-9_]+)\s*", part)
        if not rm:
            die(f"unsupported REMOVE clause {part!r}")
        attr = names[rm.group(1)] if rm.group(1).startswith("#") else rm.group(1)
        item.pop(attr, None)
    for part in m.group(1).split(","):
        pm = re.fullmatch(r"\s*(#?[A-Za-z0-9_]+)\s*=\s*(:[A-Za-z0-9_]+)\s*", part)
        if not pm:
            die(f"unsupported SET clause {part!r}")
        attr = pm.group(1)
        attr = names[attr] if attr.startswith("#") else attr
        if pm.group(2) not in values:
            die(f"undefined value {pm.group(2)}")
        item[attr] = values[pm.group(2)]


def main():
    op, o = parse_args(sys.argv[1:])
    for need in ("--region", "--table-name", "--key"):
        if not o.get(need):
            die(f"{op} without {need}")
    key = json.loads(o["--key"])
    if list(key) != ["pk"] or list(key["pk"]) != ["S"]:
        die(f"key must be exactly {{pk: {{S: …}}}}: {key}")
    pk = key["pk"]["S"]
    state_path = os.environ["FAKE_DDB_STATE"]
    log_path = os.environ.get("FAKE_DDB_LOG")
    with open(state_path + ".lock", "a+") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            with open(state_path) as fh:
                table = json.load(fh)
        except FileNotFoundError:
            table = {}
        result = "ok"
        # FAKE_DDB_FAIL_NTH=<n>：第 n 次 update-item 报限流（只那一次）。计数存在状态文件旁边，与表同一把锁。
        nth = os.environ.get("FAKE_DDB_FAIL_NTH")
        if nth and op == "update-item":
            cnt_path = state_path + ".updates"
            try:
                with open(cnt_path) as fh:
                    cnt = int(fh.read() or "0") + 1
            except FileNotFoundError:
                cnt = 1
            with open(cnt_path, "w") as fh:
                fh.write(str(cnt))
            if cnt == int(nth):
                result = "injected-error"
        if os.environ.get("FAKE_DDB_FAIL") == op:
            result = "injected-error"
        elif op == "get-item":
            item = table.get(pk)
            if item is not None:
                proj = o.get("--projection-expression")
                if proj is not None:
                    item = {k: v for k, v in item.items() if k in [p.strip() for p in proj.split(",")]}
                print(json.dumps({"Item": item}))
            elif os.environ.get("FAKE_DDB_EMPTY_GET") != "blank":
                print("{}")
            result = "hit" if item is not None else "miss"
        elif result == "ok":
            names = json.loads(o.get("--expression-attribute-names") or "{}")
            values = json.loads(o.get("--expression-attribute-values") or "{}")
            if "--update-expression" not in o:
                die("update-item without --update-expression")
            item = dict(table.get(pk) or {})
            cond = o.get("--condition-expression")
            if cond is not None and not Cond(tokens(cond), names, values, item).parse():
                result = "condition-failed"
            else:
                item["pk"] = {"S": pk}
                apply_update(o["--update-expression"], names, values, item)
                table[pk] = item
                with open(state_path + ".tmp", "w") as fh:
                    json.dump(table, fh)
                os.replace(state_path + ".tmp", state_path)
        if log_path:
            with open(log_path, "a") as fh:
                fh.write(f"{op} {pk} {result}\n")
    if result == "injected-error" and os.environ.get("FAKE_DDB_FAIL_KIND") == "connect":
        # 连不上端点时 AWS CLI 打的是这句，没有 `(<代号>)`，退出码 255
        print('\nCould not connect to the endpoint URL: "https://dynamodb.us-west-2.amazonaws.com/"',
              file=sys.stderr)
        sys.exit(255)
    if result == "injected-error":
        service_error(op, "ProvisionedThroughputExceededException",
                      "The level of configured provisioned throughput for the table was exceeded.")
    if result == "condition-failed":
        service_error(op, "ConditionalCheckFailedException", "The conditional request failed")


if __name__ == "__main__":
    main()
