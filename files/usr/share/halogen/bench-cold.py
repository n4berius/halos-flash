# halogenctl bench runs Halogen's sweep tool through this file (python3 -I -c, inside Halogen's
# image, so no mount is needed): bench-cold.py <tool> <tool's arguments>.
#
# The tool builds the same prompts on every run, so from the second run on Halogen's prompt cache
# (on disk, it outlives restarts) already holds them and answers the prefill in a fraction of a
# second: a 32K prompt then "reads" at 165,000 tok/s. Here every prompt-reading prompt starts with
# a word that is new for this run, so the cache can't match it and each prefill is cold, as in the
# "cache on (a cold request)" rows of Halogen's docs/performance.md. The tool's own prompts,
# lengths and timing are otherwise unchanged. The answer-writing prompts stay as they are: the tool
# itself reuses them across its passes. Its JSON also gets "halos_cold": the tokens the cache
# served for each prefill pass (llama-server's timings.cache_n), so the report can tell if one
# wasn't cold.
import contextlib
import importlib.util
import io
import json
import secrets
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("halogen_bench", path)
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
missing = [n for n in ("lead_line", "ask", "main") if not callable(getattr(tool, n, None))]
if missing:
    sys.exit("halOS: Halogen's sweep tool has changed (no %s), so its prompts can't be made new "
             "for this run" % ", ".join(missing))

salt = "Run %s. " % secrets.token_hex(6)
lead_line, ask = tool.lead_line, tool.ask
passes = []


def new_lead(i):
    return salt + lead_line(i)


def counted_ask(api, prompt, max_tokens, *rest, **kw):
    d, wall = ask(api, prompt, max_tokens, *rest, **kw)
    # Prefill passes ask for one token. The short requests that size the prompts also start with
    # the run's word but are under 256 tokens, so they aren't counted.
    if max_tokens == 1 and isinstance(prompt, str) and prompt.startswith(salt):
        tokens = (d.get("usage") or {}).get("prompt_tokens") or 0
        if tokens >= 256:
            passes.append({"tokens": tokens, "cached": (d.get("timings") or {}).get("cache_n") or 0})
    return d, wall


tool.lead_line, tool.ask = new_lead, counted_ask
sys.argv = [path] + sys.argv[2:]
out = io.StringIO()
with contextlib.redirect_stdout(out):
    rc = tool.main()
text = out.getvalue()
start = text.find("\n{")
try:
    result = json.loads(text[start + 1:]) if start >= 0 else None
except ValueError:
    result = None
if isinstance(result, dict):
    # Every prefill pass must have been seen with this run's word, or a later tool builds its
    # timed prompts some other way and they may be warm again: then refuse, rather than report.
    rows = result.get("rows") if isinstance(result.get("rows"), list) else []
    want = sum(1 for r in rows if isinstance(r, dict) and str(r.get("test", "")).startswith("pp"))
    want *= result.get("reps") if isinstance(result.get("reps"), int) else 1
    if len(passes) < want:
        sys.exit("halOS: only %d of %d prompt-reading passes started with this run's word, so "
                 "Halogen's sweep tool has changed and the speeds may come from the prompt cache"
                 % (len(passes), want))
    result["halos_cold"] = {"passes": passes}
    print(text[:start + 1] + json.dumps(result, indent=2))
else:
    print(text, end="")
sys.exit(rc)
