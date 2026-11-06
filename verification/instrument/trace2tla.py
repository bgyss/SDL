#!/usr/bin/env python3
"""Turn an NDJSON trace from an instrumented SDL run into TraceData.tla modules.

    trace2tla.py audio_device <trace.ndjson> <outdir>    one module per audio device
    trace2tla.py events_wait  <trace.ndjson> <outdir>    one module for the whole run

Each module goes to <outdir>/<n>/TraceData.tla. The mapping from log lines to model steps is
described in the spec's Trace.tla. Anything the mapping does not expect is an error: the
converter never drops a line it does not understand.
"""
import json
import os
import sys


def tla_str(s):
    return '"' + s + '"'


def write_module(path, log, extra):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    recs = []
    for e in log:
        recs.append("[t |-> %s, a |-> %s, v |-> %d, ok |-> %s]"
                    % (tla_str(e["t"]), tla_str(e["a"]), e["v"], "TRUE" if e.get("ok") else "FALSE"))
    with open(path, "w") as f:
        f.write("---- MODULE TraceData ----\n")
        f.write("EXTENDS Integers, Sequences\n")
        for name, value in extra:
            f.write("%s == %s\n" % (name, value))
        f.write("TraceLog == <<\n  " + ",\n  ".join(recs) + "\n>>\n")
        f.write("====\n")


def audio_device(lines, outdir):
    by_dev = {}
    for e in lines:
        by_dev.setdefault(e["id"], []).append(e)
    n = 0
    for dev, evs in sorted(by_dev.items()):
        if not any(e["a"] == "disc_ref" for e in evs):
            continue  # not a device the workload disconnected (e.g. a default device)
        main_tid = next(e["tid"] for e in evs if e["a"] == "disc_ref")
        current = {}   # looker thread -> model looker currently running on it
        lookers = []
        log = []
        for e in evs:
            a, tid, handler = e["a"], e["tid"], e["role"] == "handler"
            if handler and tid != main_tid:
                raise SystemExit("device %d: handler ran on thread %d, not the main thread" % (dev, tid))
            if a == "find_none":
                continue  # did not see the device: no model step
            if a == "disc_ref":
                log.append(dict(t="main", a="disc_ref", v=e["v"]))
            elif a in ("find_ref", "find_dead"):
                if handler:
                    log.append(dict(t="main", a="m_obtain", v=e["v"]))
                else:
                    name = "l%d" % (len(lookers) + 1)
                    lookers.append(name)
                    current[tid] = name
                    log.append(dict(t=name, a="l_find", v=e["v"], ok=(a == "find_ref")))
            elif a == "release":
                if handler:
                    log.append(dict(t="main", a="m_release", v=e["v"]))
                else:
                    log.append(dict(t=current[tid], a="l_use", v=e["v"]))
            elif a in ("m_unref_list", "m_unref_disc"):
                log.append(dict(t="main", a=a, v=-1))
            elif a in ("u_dec", "u_remove", "u_free"):
                who = "main" if handler else current.get(tid)
                if who is None:
                    raise SystemExit("device %d: %s on thread %d outside any lookup" % (dev, a, tid))
                log.append(dict(t=who, a=a, v=e["v"] if a == "u_dec" else -1))
            else:
                raise SystemExit("device %d: unexpected action %r" % (dev, a))
        n += 1
        write_module(os.path.join(outdir, str(n), "TraceData.tla"), log,
                     [("TraceLookers", "{" + ", ".join(tla_str(x) for x in lookers) + "}")])
    return n


def events_wait(lines, outdir):
    waiter_tid = next(e["tid"] for e in lines if e["a"].startswith("w_"))
    current = {}      # thread -> model producer whose push it is completing
    producers = []
    log = []
    for e in lines:
        a, tid, role = e["a"], e["tid"], e["role"]
        if a == "p_push":
            if e["v"] != 1:
                raise SystemExit("line %d: an ADD of %d events (the model pushes one)" % (e["n"], e["v"]))
            name = "p%d" % (len(producers) + 1)
            producers.append(name)
            current[tid] = name
            log.append(dict(t=name, a="p_push", v=1))
        elif a in ("p_swap", "p_post"):
            if tid not in current:
                raise SystemExit("line %d: %s with no push before it on thread %d" % (e["n"], a, tid))
            log.append(dict(t=current[tid], a=a, v=e["v"], ok=(e["v"] == 1)))
            if a == "p_post":
                del current[tid]
        elif a in ("w_pump", "peep_get"):
            if tid != waiter_tid or role not in ("w_entry", "w_loop"):
                raise SystemExit("line %d: %s outside the waiter (thread %d, role %r)" % (e["n"], a, tid, role))
            entry = role == "w_entry"
            if a == "w_pump":
                log.append(dict(t="w", a="w_epump" if entry else "w_pump", v=0))
            else:
                log.append(dict(t="w", a="w_epeep" if entry else "w_peep", v=e["v"]))
        elif a in ("w_set", "w_untake", "w_enter", "w_wait_ret", "w_clear"):
            if tid != waiter_tid:
                raise SystemExit("line %d: %s on thread %d, not the waiter" % (e["n"], a, tid))
            log.append(dict(t="w", a=a, v=e["v"]))
        else:
            raise SystemExit("line %d: unexpected action %r" % (e["n"], a))
    write_module(os.path.join(outdir, "1", "TraceData.tla"), log,
                 [("TraceProducers", "{" + ", ".join(tla_str(x) for x in producers) + "}")])
    return 1


def main():
    spec, path, outdir = sys.argv[1:4]
    with open(path) as f:
        lines = [json.loads(l) for l in f if l.strip()]
    lines.sort(key=lambda e: e["n"])
    if spec == "audio_device":
        n = audio_device(lines, outdir)
    elif spec == "events_wait":
        n = events_wait(lines, outdir)
    else:
        raise SystemExit("unknown spec " + spec)
    print(n)


if __name__ == "__main__":
    main()
