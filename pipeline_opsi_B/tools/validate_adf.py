"""
Static validation of the generated ADF resources:
  - expression syntax (own parser for the ADF expression language subset used) and function names
  - activity(), variables(), pipeline().parameters, dataset(), item() references and their scope
  - referenced activity must be upstream (dependsOn chain) of the referencing activity / container
  - dependsOn targets are siblings; activity names unique and <= 55 chars
  - container nesting rules (no ForEach/Until in ForEach/Until; no container inside If/Switch)
  - SetVariable not self-referencing
  - stored procedure names, parameter names, required parameters and result columns vs SQL contract (v0.6 + v0.7-opsiB)
  - Execute Pipeline and dataset parameters vs target definitions
  - ARM template: no unescaped '[' strings, dependsOn resolvable
Also evaluates the dynamic T-SQL expressions with sample values (scenario tests).
"""
import json, os, re, sys, glob

ROOT = sys.argv[1]
CONTRACT = json.load(open(os.path.join(os.path.dirname(__file__), "sql_contract.json")))
errors, warnings = [], []
def err(m): errors.append(m)
def warn(m): warnings.append(m)

FUNCS = {"concat", "if", "equals", "empty", "trim", "replace", "formatdatetime", "string", "coalesce", "not", "and",
         "or", "contains", "bool", "int", "greater", "substring", "convertfromutc", "utcnow", "createarray", "json",
         "activity", "pipeline", "variables", "item", "dataset", "length", "addseconds", "mul"}
CONTAINERS = {"ForEach", "Until", "IfCondition", "Switch"}

# ------------------------------------------------------------------ expression parser / evaluator
class Tok:
    def __init__(s, k, v, p): s.k, s.v, s.p = k, v, p

def lex(src):
    i, out = 0, []
    while i < len(src):
        c = src[i]
        if c.isspace(): i += 1; continue
        if c == "'":
            j, buf = i + 1, []
            while True:
                if j >= len(src): raise SyntaxError(f"unterminated string at {i}")
                if src[j] == "'":
                    if j + 1 < len(src) and src[j + 1] == "'": buf.append("'"); j += 2; continue
                    break
                buf.append(src[j]); j += 1
            out.append(Tok("str", "".join(buf), i)); i = j + 1; continue
        if c.isdigit() or (c == "-" and i + 1 < len(src) and src[i+1].isdigit()):
            j = i + 1
            while j < len(src) and (src[j].isdigit() or src[j] == "."): j += 1
            out.append(Tok("num", src[i:j], i)); i = j; continue
        if c.isalpha() or c == "_":
            j = i
            while j < len(src) and (src[j].isalnum() or src[j] == "_"): j += 1
            out.append(Tok("id", src[i:j], i)); i = j; continue
        if src.startswith("?.", i): out.append(Tok("?.", "?.", i)); i += 2; continue
        if c in "().,[]": out.append(Tok(c, c, i)); i += 1; continue
        raise SyntaxError(f"unexpected char {c!r} at {i}")
    return out

class Parser:
    def __init__(s, toks): s.t, s.i = toks, 0
    def peek(s): return s.t[s.i] if s.i < len(s.t) else None
    def take(s, k=None):
        t = s.peek()
        if t is None or (k and t.k != k): raise SyntaxError(f"expected {k} got {t.v if t else 'EOF'}")
        s.i += 1; return t
    def expr(s):
        t = s.take()
        if t.k == "str": node = ("str", t.v)
        elif t.k == "num": node = ("num", float(t.v) if "." in t.v else int(t.v))
        elif t.k == "id":
            if t.v in ("true", "false") and (s.peek() is None or s.peek().k != "("):
                node = ("bool", t.v == "true")
            else:
                s.take("("); args = []
                if s.peek().k != ")":
                    args.append(s.expr())
                    while s.peek().k == ",": s.take(","); args.append(s.expr())
                s.take(")")
                node = ("call", t.v, args)
        else: raise SyntaxError(f"unexpected token {t.v}")
        while s.peek() is not None and s.peek().k in (".", "?.", "["):
            op = s.take()
            if op.k == "[":
                idx = s.expr(); s.take("]"); node = ("idx", node, idx)
            else:
                node = ("prop", node, s.take("id").v, op.k == "?.")
        return node

def parse(src):
    p = Parser(lex(src)); n = p.expr()
    if p.peek() is not None: raise SyntaxError(f"trailing tokens at {p.peek().p}")
    return n

def walk_nodes(n):
    yield n
    if n[0] == "call":
        for a in n[2]: yield from walk_nodes(a)
    elif n[0] in ("prop",): yield from walk_nodes(n[1])
    elif n[0] == "idx": yield from walk_nodes(n[1]); yield from walk_nodes(n[2])

class Missing(Exception): pass

def ev(n, ctx):
    k = n[0]
    if k in ("str", "num", "bool"): return n[1]
    if k == "prop":
        base = ev(n[1], ctx)
        if isinstance(base, dict) and n[2] in base: return base[n[2]]
        if n[3]: return None
        raise Missing(f"property {n[2]} missing")
    if k == "idx":
        return ev(n[1], ctx)[ev(n[2], ctx)]
    f, a = n[1].lower(), n[2]
    A = lambda i: ev(a[i], ctx)
    if f == "pipeline": return ctx["pipeline"]
    if f == "variables": return ctx["variables"][A(0)]
    if f == "activity": return ctx["activities"][A(0)]
    if f == "item": return ctx["item"]
    if f == "concat":
        vals = [A(i) for i in range(len(a))]
        if any(v is None for v in vals): raise Missing("concat with null")
        return "".join(v if isinstance(v, str) else json.dumps(v) for v in vals)
    if f == "if":
        c, x, y = A(0), A(1), A(2)  # ADF evaluates eagerly: both branches must be valid
        return x if c else y
    if f == "equals": return A(0) == A(1)
    if f == "empty": v = A(0); return v is None or len(v) == 0
    if f == "trim": return A(0).strip()
    if f == "replace": return A(0).replace(A(1), A(2))
    if f == "formatdatetime":
        v = A(0)
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}.*", v): raise ValueError(f"formatDateTime invalid input {v!r}")
        return v[:10]
    if f == "string":
        v = A(0)
        if v is None: return ""
        return v if isinstance(v, str) else ("True" if v is True else "False" if v is False else str(v))
    if f == "coalesce":
        for i in range(len(a)):
            v = A(i)
            if v is not None: return v
        return None
    if f == "not": return not A(0)
    if f == "and": return all(A(i) for i in range(len(a)))
    if f == "or": return any(A(i) for i in range(len(a)))
    if f == "contains":
        c, v = A(0), A(1)
        return v in c
    if f == "bool":
        v = A(0)
        if isinstance(v, bool): return v
        if v in (0, 1): return bool(v)
        if isinstance(v, str) and v.lower() in ("true", "false"): return v.lower() == "true"
        raise ValueError(f"bool({v!r})")
    if f == "int": return int(A(0))
    if f == "greater": return A(0) > A(1)
    if f == "substring": s = A(0); st, ln = A(1), A(2); assert st + ln <= len(s); return s[st:st+ln]
    if f == "createarray": return [A(i) for i in range(len(a))]
    if f == "json": return json.loads(A(0))
    if f == "utcnow": return "2026-10-31T14:00:00Z"
    if f == "convertfromutc": A(0); return "2026-10-31 21:00:00.000"
    if f == "addseconds":
        b, n = A(0), A(1)
        if not isinstance(n, int): raise ValueError(f"addSeconds needs an integer, got {n!r}")
        return b
    if f == "mul": return A(0) * A(1)
    raise ValueError(f"no evaluator for {f}")

def evaluate(src, ctx):
    return ev(parse(src[1:]), ctx)

# ------------------------------------------------------------------ load resources
def load(kind):
    out = {}
    for f in glob.glob(os.path.join(ROOT, "adf", kind, "*.json")):
        d = json.load(open(f)); out[d["name"]] = d
        if os.path.basename(f) != d["name"] + ".json": err(f"{f}: file name differs from resource name")
    return out
LS, DS, PL, TR = load("linkedService"), load("dataset"), load("pipeline"), load("trigger")
# pipeline-agus: linked services created by the user in the factory, not part of the package
EXTERNAL_LS = {"Agus_SqlServer_dwh", "Agus_AzureBlobStorage1"}

def expr_strings(obj, skip_keys=()):
    """yield expression strings in obj, not descending into nested activity lists"""
    if isinstance(obj, dict):
        if obj.get("type") == "Expression" and isinstance(obj.get("value"), str):
            yield obj["value"]; return
        for k, v in obj.items():
            if k in skip_keys: continue
            yield from expr_strings(v, skip_keys)
    elif isinstance(obj, list):
        for v in obj: yield from expr_strings(v, skip_keys)
    elif isinstance(obj, str) and obj.startswith("@") and not obj.startswith("@@"):
        yield obj

NESTED_KEYS = ("activities", "ifTrueActivities", "ifFalseActivities", "cases", "defaultActivities")

def child_lists(a):
    tp = a.get("typeProperties", {})
    t = a["type"]
    if t in ("ForEach", "Until"): return [("body", tp.get("activities", []))]
    if t == "IfCondition": return [("true", tp.get("ifTrueActivities", [])), ("false", tp.get("ifFalseActivities", []))]
    if t == "Switch":
        return [(f"case:{c['value']}", c.get("activities", [])) for c in tp.get("cases", [])] + \
               [("default", tp.get("defaultActivities", []))]
    return []

# ------------------------------------------------------------------ per pipeline checks
for pname, p in PL.items():
    props = p["properties"]
    params = props.get("parameters", {})
    variables = props.get("variables", {})
    info = {}   # name -> dict(scope=tuple, act=a, deps=set, container=name or None)
    def collect(acts, scope, container, in_types):
        names = {a["name"] for a in acts}
        for a in acts:
            n = a["name"]
            if n in info: err(f"{pname}: duplicate activity name {n}")
            if len(n) > 55: err(f"{pname}: activity name > 55 chars {n}")
            if not re.fullmatch(r"[A-Za-z0-9_ -]+", n): err(f"{pname}: invalid activity name {n}")
            deps = set()
            for d in a.get("dependsOn", []):
                if d["activity"] not in names: err(f"{pname}/{n}: dependsOn {d['activity']} is not a sibling")
                for c in d["dependencyConditions"]:
                    if c not in ("Succeeded", "Failed", "Skipped", "Completed"): err(f"{pname}/{n}: bad condition {c}")
                deps.add(d["activity"])
            info[n] = dict(scope=scope, act=a, deps=deps, container=container)
            t = a["type"]
            if t in CONTAINERS:
                for parent_t in in_types:
                    if parent_t in ("IfCondition", "Switch"):
                        err(f"{pname}/{n}: container {t} nested inside {parent_t}")
                    if parent_t in ("ForEach", "Until") and t in ("ForEach", "Until"):
                        err(f"{pname}/{n}: {t} nested inside {parent_t}")
                for label, lst in child_lists(a):
                    collect(lst, scope + ((n, label),), n, in_types + (t,))
    collect(props["activities"], (), None, ())

    def upstream(name):
        """all activities upstream of `name`: dependsOn closure, plus upstream of every enclosing container"""
        seen, stack = set(), [name]
        while stack:
            x = stack.pop()
            for d in info[x]["deps"]:
                if d not in seen: seen.add(d); stack.append(d)
            c = info[x]["container"]
            if c and c not in seen:
                seen.add(c); stack.append(c)
        return seen

    def in_foreach_or_filter(name):
        x = name
        while x:
            if info[x]["act"]["type"] in ("ForEach", "Filter"): return True
            x = info[x]["container"]
        return False

    for n, inf in info.items():
        a = inf["act"]
        own = {k: v for k, v in a.items() if k != "typeProperties"}
        tp = {k: v for k, v in a.get("typeProperties", {}).items() if k not in NESTED_KEYS}
        exprs = list(expr_strings(own)) + list(expr_strings(tp))
        for s in exprs:
            try:
                tree = parse(s[1:])
            except SyntaxError as e:
                err(f"{pname}/{n}: expression syntax error {e}: {s[:120]}"); continue
            for node in walk_nodes(tree):
                if node[0] != "call": continue
                fn = node[1].lower()
                if fn not in FUNCS: err(f"{pname}/{n}: unknown function {node[1]}")
                if fn == "activity":
                    tgt = node[2][0][1]
                    if tgt not in info: err(f"{pname}/{n}: activity('{tgt}') not found"); continue
                    ts = info[tgt]["scope"]
                    if inf["scope"][:len(ts)] != ts:
                        err(f"{pname}/{n}: activity('{tgt}') is inside another container (scope)")
                    if a["type"] != "ForEach" or tgt != n:
                        if tgt not in upstream(n) and tgt != n:
                            err(f"{pname}/{n}: activity('{tgt}') is not upstream")
                if fn == "variables":
                    v = node[2][0][1]
                    if v not in variables: err(f"{pname}/{n}: variable {v} not declared")
                    if a["type"] == "SetVariable" and a["typeProperties"]["variableName"] == v:
                        err(f"{pname}/{n}: SetVariable references its own variable")
                if fn == "item" and not (a["type"] in ("ForEach", "Filter") and False) and not in_foreach_or_filter(inf["container"] or "") \
                        and a["type"] not in ("Filter",):
                    err(f"{pname}/{n}: item() outside ForEach/Filter")
            for m in re.finditer(r"pipeline\(\)\.parameters\.(\w+)", s):
                if m.group(1) not in params: err(f"{pname}/{n}: pipeline parameter {m.group(1)} not declared")
            # result-column references
            for m in re.finditer(r"activity\('(\w+)'\)\.output\??\.firstRow\??\.(\w+)", s):
                tgt, col = m.group(1), m.group(2)
                if tgt in info:
                    src = info[tgt]["act"].get("typeProperties", {}).get("source", {})
                    proc = src.get("sqlReaderStoredProcedureName")
                    if not proc and isinstance(src.get("sqlReaderQuery"), dict):
                        mm = re.search(r"EXEC (ret\.\w+)", src["sqlReaderQuery"]["value"]); proc = mm.group(1) if mm else None
                    if proc and proc in CONTRACT and col not in CONTRACT[proc]["columns"]:
                        err(f"{pname}/{n}: {proc} has no result column {col}")
        if a["type"] == "SetVariable" and a["typeProperties"]["variableName"] not in variables:
            err(f"{pname}/{n}: SetVariable target {a['typeProperties']['variableName']} not declared")
        # stored procedures
        src = a.get("typeProperties", {}).get("source", {})
        proc = src.get("sqlReaderStoredProcedureName")
        if proc:
            if proc not in CONTRACT: err(f"{pname}/{n}: unknown procedure {proc}")
            else:
                given = set(src.get("storedProcedureParameters", {}))
                c = CONTRACT[proc]
                for g in given - set(c["required"]) - set(c["optional"]): err(f"{pname}/{n}: {proc} has no parameter @{g}")
                for r in set(c["required"]) - given: err(f"{pname}/{n}: {proc} required parameter @{r} missing")
                for k, v in src.get("storedProcedureParameters", {}).items():
                    if v["type"] not in ("Int64", "Int32", "Int16", "String", "Boolean", "DateTime", "Guid"): err(f"{pname}/{n}: param type {v['type']}")
            if a["type"] == "Lookup" and not CONTRACT.get(proc, {}).get("columns"):
                err(f"{pname}/{n}: Lookup on {proc} that returns no result set")
        q = src.get("sqlReaderQuery")
        if isinstance(q, dict):
            mm = re.search(r"EXEC (ret\.\w+)", q["value"])
            if not mm or mm.group(1) not in CONTRACT: err(f"{pname}/{n}: query does not call a known procedure")
            else:
                for pm in re.findall(r"@(\w+) = ", q["value"]):
                    c = CONTRACT[mm.group(1)]
                    if pm not in c["required"] + c["optional"]: err(f"{pname}/{n}: {mm.group(1)} has no parameter @{pm}")
        # execute pipeline
        if a["type"] == "ExecutePipeline":
            child = a["typeProperties"]["pipeline"]["referenceName"]
            if child not in PL: err(f"{pname}/{n}: pipeline {child} not found")
            else:
                cp = PL[child]["properties"].get("parameters", {})
                given = set(a["typeProperties"].get("parameters", {}))
                for g in given - set(cp): err(f"{pname}/{n}: {child} has no parameter {g}")
                for r in [k for k, v in cp.items() if "defaultValue" not in v]:
                    if r not in given: err(f"{pname}/{n}: {child} required parameter {r} missing")
        # dataset refs
        def ds_refs(o):
            if isinstance(o, dict):
                if o.get("type") == "DatasetReference": yield o
                for v in o.values(): yield from ds_refs(v)
            elif isinstance(o, list):
                for v in o: yield from ds_refs(v)
        for r in ds_refs({k: v for k, v in a.items() if k != "typeProperties"} | {"tp": tp}):
            dn = r["referenceName"]
            if dn not in DS: err(f"{pname}/{n}: dataset {dn} not found"); continue
            dp = DS[dn]["properties"].get("parameters", {})
            given = set(r.get("parameters", {}))
            for g in given - set(dp): err(f"{pname}/{n}: dataset {dn} has no parameter {g}")
            for need in [k for k, v in dp.items() if "defaultValue" not in v]:
                if need not in given: err(f"{pname}/{n}: dataset {dn} parameter {need} missing")

# datasets reference linked services; dataset() refs
for dn, d in DS.items():
    ls = d["properties"]["linkedServiceName"]["referenceName"]
    if ls not in LS and ls not in EXTERNAL_LS: err(f"{dn}: linked service {ls} not found")
    for s in expr_strings(d["properties"]):
        for m in re.finditer(r"dataset\(\)\.(\w+)", s):
            if m.group(1) not in d["properties"].get("parameters", {}): err(f"{dn}: dataset param {m.group(1)} missing")
for tn, t in TR.items():
    for pr in t["properties"]["pipelines"]:
        if pr["pipelineReference"]["referenceName"] not in PL: err(f"{tn}: pipeline not found")

# ------------------------------------------------------------------ system variables (ADF documentation)
SYSVARS = {"DataFactory", "Pipeline", "RunId", "TriggerType", "TriggerId", "TriggerName", "TriggerTime", "GroupId",
           "TriggeredByPipelineName", "TriggeredByPipelineRunId", "parameters", "globalParameters"}
for pn, p in PL.items():
    for m in re.finditer(r"pipeline\(\)\.(\w+)", json.dumps(p)):
        if m.group(1) not in SYSVARS: err(f"{pn}: unsupported system variable pipeline().{m.group(1)}")

# ------------------------------------------------------------------ ARM checks
arm = json.load(open(os.path.join(ROOT, "arm", "ARMTemplateForFactory.json")))
names = {r["name"].split("'/")[1].rstrip("')]") if "'/" in r["name"] else r["name"] for r in arm["resources"]}
def arm_strings(o):
    if isinstance(o, dict):
        for v in o.values(): yield from arm_strings(v)
    elif isinstance(o, list):
        for v in o: yield from arm_strings(v)
    elif isinstance(o, str): yield o
for r in arm["resources"]:
    for s in arm_strings(r["properties"]):
        if s.startswith("[") and not s.startswith("[["):
            for pm in re.findall(r"parameters\('(\w+)'\)", s):
                if pm not in arm["parameters"]: err(f"ARM: parameter {pm} not declared")
            if not re.match(r"\[(parameters|concat)\(", s): err(f"ARM: unescaped '[' string {s[:60]}")
    for d in r["dependsOn"]:
        tgt = re.search(r"/(\w+)/(\w+)'\)\]$", d).group(2)
        if tgt not in names: err(f"ARM: dependsOn {tgt} not in template")
kinds = [r["type"].split("/")[-1] for r in arm["resources"]]
print("ARM resources:", {k: kinds.count(k) for k in set(kinds)})

# ------------------------------------------------------------------ scenario evaluation of dynamic T-SQL
def ctxm(params, variables=None, acts=None, trig="Manual"):
    return {"pipeline": {"parameters": params, "RunId": "6f1c2b9e-0000-4000-8000-000000000001",
                         "TriggerType": trig, "TriggerName": "Sandbox"},
            "variables": variables or {}, "activities": acts or {}, "item": None}

def act_expr(pl, actname, path):
    def find(acts):
        for a in acts:
            if a["name"] == actname: return a
            for _, lst in child_lists(a):
                r = find(lst)
                if r: return r
    a = find(PL[pl]["properties"]["activities"])
    o = a
    for k in path: o = o[k]
    return o["value"] if isinstance(o, dict) else o

PB = {k: k.replace("PL_RET_", "PL_RETB_") for k in ["PL_RET_01_InitialCutoff_Master", "PL_RET_02_DailyRoutine_Master",
      "PL_RET_03_Table_Process", "PL_RET_03A_Table_DataSteps", "PL_RET_04_ArchiveExpiry"]}
print("\n--- scenario: StartRunAndGetTables (PL-01 / PL-02) ---")
q = act_expr(PB["PL_RET_01_InitialCutoff_Master"], "LKP_StartRunAndGetTables", ["typeProperties", "source", "sqlReaderQuery"])
for prm in [dict(TableConfigIdList="3,1", RunDate="", DowntimeReference="", TriggeredBy="", ValidateOnly=False),
            dict(TableConfigIdList=None, RunDate=None, DowntimeReference=None, TriggeredBy=None, ValidateOnly=False),
            dict(TableConfigIdList="3,1", RunDate=" 2026-10-27 ", DowntimeReference="CR-0042", TriggeredBy="Dimas O'Neil", ValidateOnly=False),
            dict(TableConfigIdList="", RunDate="", DowntimeReference="CR-0042", TriggeredBy="", ValidateOnly=True)]:
    v = evaluate(q, ctxm(prm)); print(v)
    if "@TableConfigIdList = " not in v: err("StartRunAndGetTables: list parameter missing")
v = evaluate(act_expr(PB["PL_RET_02_DailyRoutine_Master"], "LKP_StartRunAndGetTables", ["typeProperties", "source", "sqlReaderQuery"]),
             ctxm(dict(RunDate="", TriggeredBy=""), trig="ScheduleTrigger"))
print(v)
if "@TableConfigIdList = NULL" not in v: err("PL-02: list must be NULL")
q = act_expr(PB["PL_RET_01_InitialCutoff_Master"], "FLT_Tables", ["typeProperties", "condition"])
for it, exp in (({"TableConfigId": None}, False), ({"TableConfigId": 36}, True)):
    c = ctxm({}); c["item"] = it; got = evaluate(q, c); print("FLT_Tables", it, "->", got)
    if got != exp: err(f"FLT_Tables expected {exp} for {it}")

print("\n--- scenario: EndTable (PL-03) ---")
q = act_expr(PB["PL_RET_03_Table_Process"], "LKP_EndTable", ["typeProperties", "source", "sqlReaderQuery"])
bt = {"output": {"firstRow": {"TableLogId": 1234, "BeginResult": "PROCEED", "CanRunArchiveExpiry": True,
                              "PendingResumeTableLogId": None, "ArchiveCutoffDate": "2018-10-31",
                              "IdentifyResult": "SUCCEEDED", "NextAction": "EXPORT"}}}
print(evaluate(q, ctxm({}, {"vErrDataSteps": "", "vErrArchiveExpiry": ""}, {"LKP_BeginTableAndIdentify": bt})))
print(evaluate(q, ctxm({}, {"vErrDataSteps": "Operation on target 'CPY' failed: can't connect", "vErrArchiveExpiry": "x"},
                       {"LKP_BeginTableAndIdentify": bt})))
for col, exp in (("IdentifyResult", "SUCCEEDED"), ("NextAction", "EXPORT"), ("PendingResumeTableLogId", "")):
    q = act_expr(PB["PL_RET_03_Table_Process"], "EXEC_DataSteps", ["typeProperties", "parameters", col])
    got = evaluate(q, ctxm({}, acts={"LKP_BeginTableAndIdentify": bt})); print(col, "->", repr(got))
    if got != exp: err(f"EXEC_DataSteps {col}: expected {exp!r}, got {got!r}")
b2 = {"output": {"firstRow": {"TableLogId": 1, "PendingResumeTableLogId": 991, "IdentifyResult": None, "NextAction": None}}}
for col, exp in (("IdentifyResult", ""), ("NextAction", "NONE"), ("PendingResumeTableLogId", "991")):
    q = act_expr(PB["PL_RET_03_Table_Process"], "EXEC_DataSteps", ["typeProperties", "parameters", col])
    got = evaluate(q, ctxm({}, acts={"LKP_BeginTableAndIdentify": b2})); print("pending resume:", col, "->", repr(got))
    if got != exp: err(f"EXEC_DataSteps (resume) {col}: expected {exp!r}, got {got!r}")

print("\n--- scenario: processing path (PL-03A) ---")
q = act_expr(PB["PL_RET_03A_Table_DataSteps"], "SET_ProcessingPath", ["typeProperties", "value"])
cases = [("DAILY_ROUTINE", "BATCH_DELETE", "SUCCEEDED", "EXPORT", "BATCH"),
         ("DAILY_ROUTINE", "TABLE_REBUILD", "SUCCEEDED", "EXPORT", "BATCH"),
         ("DAILY_ROUTINE", "BATCH_DELETE", "SUCCEEDED", "NONE", "NONE"),
         ("INITIAL_CUTOFF", "BATCH_DELETE", "SUCCEEDED", "VALIDATE", "BATCH"),
         ("INITIAL_CUTOFF", "TABLE_REBUILD", "SUCCEEDED", "EXPORT", "REBUILD"),
         ("INITIAL_CUTOFF", "TABLE_REBUILD", "SUCCEEDED", "NONE", "IC_NODATA"),
         ("INITIAL_CUTOFF", "BATCH_DELETE", "FAILED", "NONE", "NONE"),
         ("INITIAL_CUTOFF", "BATCH_DELETE", "", "NONE", "NONE")]
for pt, m, res, na, exp in cases:
    got = evaluate(q, ctxm({"ProcessType": pt, "InitialCutoffMethod": m}, {"vIdentResult": res, "vNextAction": na}))
    print(f"{pt:15} {m:14} {res:9} {na:8} -> {got}")
    if got != exp: err(f"path expression: expected {exp} got {got}")

print("\n--- scenario: export chunk loop (PL-03E) ---")
qc = act_expr("PL_RETB_03E_Export_Chunks", "SET_Continue_FromChunk", ["typeProperties", "value"])
qk = act_expr("PL_RETB_03E_Export_Chunks", "SET_Cleanup_FromChunk", ["typeProperties", "value"])
qi = act_expr("PL_RETB_03E_Export_Chunks", "IF_ExportChunk", ["typeProperties", "expression"])
for ce, rac, cl, exp in [(True, 12, False, ("1", "0", True)), (True, 0, False, ("0", "0", True)),
                         (False, 0, True, ("0", "1", False)), (False, 0, False, ("0", "0", False))]:
    a = {"LKP_GetExportChunk": {"output": {"value": [{"ContinueExport": ce, "RemainingAfterChunk": rac, "CleanupRequired": cl}]}}}
    got = (evaluate(qc, ctxm({}, acts=a)), evaluate(qk, ctxm({}, acts=a)), evaluate(qi, ctxm({}, acts=a)))
    print(f"ContinueExport={ce} RemainingAfterChunk={rac} CleanupRequired={cl} -> vContinue/vCleanup/export = {got}")
    if got != exp: err(f"chunk loop: expected {exp} got {got}")
q = act_expr("PL_RETB_03G_Export_Chunk", "LKP_LogExport_Succeeded",
             ["typeProperties", "source", "storedProcedureParameters", "ExportStartTime", "value"])
print("ExportStartTime:", evaluate(q, ctxm({}, acts={"CPY_ExportBusinessDate": {"output": {"copyDuration": 14}}})))

print("\n--- scenario: archive expiry (PL-04) ---")
q = act_expr(PB["PL_RET_04_ArchiveExpiry"], "GMD_ListCutoffYearFiles", ["typeProperties", "dataset", "parameters", "FolderPath"])
fp = evaluate(q, ctxm({"BlobPath": "bos.jti_sd_branddistdetail", "ArchiveCutoffDate": "2018-10-27"}))
print("FILE level folder:", fp)
if fp != "2018/bos.jti_sd_branddistdetail": err(f"PL-04 FILE folder expected 2018/bos.jti_sd_branddistdetail, got {fp}")
q = act_expr(PB["PL_RET_04_ArchiveExpiry"], "GMD_ListYearFolders", ["typeProperties", "dataset", "parameters", "FolderPath"])
if evaluate(q, ctxm({})) != "": err("PL-04 root folder must be empty")
qw = act_expr(PB["PL_RET_04_ArchiveExpiry"], "DEL_ExpiredItem", ["typeProperties", "storeSettings", "wildcardFileName"])
qr = act_expr(PB["PL_RET_04_ArchiveExpiry"], "DEL_ExpiredItem", ["typeProperties", "storeSettings", "recursive"])
for it, exp in (({"Level": "YEAR", "FolderPath": "2017/bos.t", "FileName": ""}, ("*", True)),
                ({"Level": "FILE", "FolderPath": "2018/bos.t", "FileName": "bos.t_20181026.parquet"}, ("bos.t_20181026.parquet", False))):
    c = ctxm({}); c["item"] = it
    got = (evaluate(qw, c), evaluate(qr, c)); print("Delete:", it, "->", got)
    if got != exp: err(f"PL-04 delete settings expected {exp} got {got}")
q = act_expr(PB["PL_RET_04_ArchiveExpiry"], "LKP_GetExpiredArchiveItems",
             ["typeProperties", "source", "storedProcedureParameters", "FileItemsJson", "value"])
for out in ({"exists": False}, {"exists": True, "childItems": [{"name": "bos.t_20181026.parquet", "type": "File"}]}):
    v = evaluate(q, ctxm({}, acts={"GMD_ListCutoffYearFiles": {"output": out}}))
    print(out.get("exists"), "->", v if isinstance(v, str) else json.dumps(v))

print("\nERRORS:", len(errors))
for e in errors: print("  E", e)
print("WARNINGS:", len(warnings))
for w in warnings: print("  W", w)
sys.exit(1 if errors else 0)
