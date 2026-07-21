#!/usr/bin/env python3
"""Host-safe PC-18 fixture validator and result scorer."""
import argparse, json, math, statistics, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "pc18-fixtures"
MANIFEST = ROOT / "manifest.json"

def load_manifest(): return json.loads(MANIFEST.read_text(encoding="utf-8"))

def validate_manifest(m):
    errors=[]; cases=m.get("cases",[]); ids=[c.get("id") for c in cases]
    if ids != ["C1","C2","C3","C4","C5","C6","O1","O2","O3","O4","O5","O6"]: errors.append("case IDs/order are not frozen")
    if {c["id"] for c in cases if c.get("holdout")} != {"C5","C6","O5","O6"}: errors.append("holdout set mismatch")
    for c in cases:
        for key in ("subject","intent","expected","required_claims","forbidden_claims","allowed_region","human_rationale","page_id","lasso_region","asset"):
            if key not in c: errors.append(f"{c.get('id')}: missing {key}")
        p=ROOT/c.get("asset","")
        if not p.is_file() or p.stat().st_size==0: errors.append(f"{c.get('id')}: absent asset {p}")
        e=c.get("expected",{}); spatial=e.get("outcome")=="spatialGuidance"
        if spatial != (e.get("pin_count")==1 and e.get("persists") is True and c.get("allowed_region") is not None): errors.append(f"{c.get('id')}: persistent/geometry contract mismatch")
        if not spatial and (e.get("pin_count")!=0 or e.get("persists") is not False or c.get("allowed_region") is not None): errors.append(f"{c.get('id')}: non-Pin contract mismatch")
    return errors

def inside(target, region):
    if not isinstance(target,list) or len(target)!=2 or not all(isinstance(v,(int,float)) and math.isfinite(v) for v in target): return False
    x,y,w,h=region; return x<=target[0]<=x+w and y<=target[1]<=y+h

def score(m, result_rows):
    cases={c["id"]:c for c in m["cases"]}; rows={r.get("id"):r for r in result_rows}; outcome_ok=0; required_hit=0; required_total=0
    pins=0; correct_pins=0; catastrophic=0; shallow=0; geometry_pass=0; geometry_total=0; latencies=[]; per=[]
    catastrophic_tags={"false_academic_claim","fabricated_evidence","false_correctness_verdict","unsafe_boundary_claim"}
    for cid,c in cases.items():
        r=rows.get(cid,{}) ; e=c["expected"]
        exact=r.get("outcome")==e["outcome"] and r.get("reason")==e["reason"] and r.get("pin_count",0)==e["pin_count"] and r.get("persists",False)==e["persists"]
        outcome_ok += bool(exact)
        claims=set(r.get("claims",[])); hits=len(set(c["required_claims"]) & claims); required_hit+=hits; required_total+=len(c["required_claims"])
        forbidden=set(c["forbidden_claims"]) & set(r.get("forbidden_claims",[])); tags=set(r.get("error_tags",[]))
        catastrophic += bool(tags & catastrophic_tags); shallow += bool("transcription_only" in tags or "transcription_only" in forbidden)
        n=max(0,int(r.get("pin_count",0))); pins+=n
        geometry=True
        if n or e["outcome"]=="spatialGuidance":
            geometry_total+=1; geometry=bool(n==1 and c["allowed_region"] and inside(r.get("target"),c["allowed_region"])); geometry_pass+=geometry
        elif r.get("target") is not None: geometry=False
        critical=set(c["critical_claims"]).issubset(claims)
        if n==1 and e["outcome"]=="spatialGuidance" and exact and critical and not forbidden and geometry and not tags: correct_pins+=1
        if isinstance(r.get("latency_ms"),(int,float)) and r["latency_ms"]>=0: latencies.append(r["latency_ms"])
        per.append({"id":cid,"outcome_correct":exact,"required_claims":f"{hits}/{len(c['required_claims'])}","geometry":geometry,"forbidden":sorted(forbidden)})
    ordered=sorted(latencies)
    percentile=lambda p: ordered[max(0,math.ceil(p*len(ordered))-1)] if ordered else None
    return {"case_count":len(cases),"outcome_correct":outcome_ok,"outcome_accuracy":outcome_ok/len(cases),"required_guidance_recall":required_hit/required_total,"accepted_pin_precision":None if pins==0 else correct_pins/pins,"accepted_pin_count":pins,"catastrophic_error_count":catastrophic,"shallow_narration_count":shallow,"geometry_pass":f"{geometry_pass}/{geometry_total}","latency_p50_ms":statistics.median(latencies) if latencies else None,"latency_p90_ms":percentile(.9),"per_case":per}

def oracle(m):
    rows=[]
    for c in m["cases"]:
        e=c["expected"]; row={"id":c["id"],**e,"claims":c["required_claims"],"forbidden_claims":[],"error_tags":[],"latency_ms":1000}
        if c["allowed_region"]:
            x,y,w,h=c["allowed_region"]; row["target"]=[x+w/2,y+h/2]
        rows.append(row)
    return rows

def abstain(m):
    return [{"id":c["id"],"outcome":"needsInput","reason":"unsupportedContent","pin_count":0,"persists":False,"claims":[],"forbidden_claims":[],"error_tags":[],"latency_ms":100} for c in m["cases"]]

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("results",nargs="?"); ap.add_argument("--self-test",action="store_true"); args=ap.parse_args()
    m=load_manifest(); errors=validate_manifest(m)
    if errors: print(json.dumps({"manifest_errors":errors},indent=2)); return 1
    if args.self_test:
        good=score(m,oracle(m)); bad=score(m,abstain(m))
        assert good["outcome_correct"]==12 and good["required_guidance_recall"]==1 and good["accepted_pin_precision"]==1
        assert bad["outcome_correct"]<11 and bad["required_guidance_recall"]==0 and bad["accepted_pin_precision"] is None
        print(json.dumps({"manifest":"PASS","cases":12,"holdouts":["C5","C6","O5","O6"],"oracle":good,"universal_abstention":bad},indent=2)); return 0
    if not args.results: print(json.dumps({"manifest":"PASS","cases":12,"holdouts":["C5","C6","O5","O6"]},indent=2)); return 0
    rows=json.loads(Path(args.results).read_text(encoding="utf-8")); print(json.dumps(score(m,rows),indent=2)); return 0

if __name__=="__main__": sys.exit(main())
