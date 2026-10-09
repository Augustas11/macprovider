"""Command classifier for claude-pretooluse-ops-guard.sh.

Reads a Claude Code PreToolUse event on stdin. Exit 0 allows the Bash call;
exit 2 blocks it and prints the reason and the entry point to use.

A rule matches only on the COMMAND WORD of a simple command: the first word
after variable assignments and wrappers (sudo, env, nohup, time, nice,
ionice, timeout, xargs, systemd-run, eval, `bash|sh -c PAYLOAD`, and the
remote command of `ssh HOST CMD`, which are parsed again). Naming a guarded
script as an argument to grep, git, cat, `bash -n` and so on is never
blocked. The command line is split on ; & && | || newlines and ( ), with
comments and heredoc bodies removed; $(...) and backtick bodies are parsed
as commands of their own.
"""

import json
import os
import re
import shlex
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

CLI = "scripts/ops/cli-release.sh"
CAT = "scripts/ops/catalog-activate.sh"
RT = "scripts/ops/pearl-runtime.sh"
DISC = "scripts/ops/discovery-renew.sh"

# Guarded workflow file stem -> entry point.
WORKFLOWS = {
    "acceptance-candidate": CLI,
    "promote-acceptance-candidate": CLI,
    "release": CLI,
    "renew-release-discovery-head": DISC,
    "verify-live-coordinator-release-rollout": CLI,
    "pearl-runtime-release": RT,
}
# Display names, used when the workflow files cannot be read.
FALLBACK_NAMES = {
    "acceptance-candidate": "Sign private acceptance candidate",
    "promote-acceptance-candidate": "Promote exact physically accepted candidate",
    "release": "Release macprovider-cli",
    "renew-release-discovery-head": "Renew signed release discovery head",
    "verify-live-coordinator-release-rollout": "Verify live coordinator release rollout",
    "pearl-runtime-release": "Release Pearl runtime",
}


def display_names():
    names = {}
    for stem, fallback in FALLBACK_NAMES.items():
        names[fallback.lower()] = stem
        path = os.path.join(REPO, ".github", "workflows", stem + ".yml")
        try:
            with open(path) as f:
                for line in f:
                    m = re.match(r"^name:\s*(.+?)\s*$", line)
                    if m:
                        names[m.group(1).strip("'\"").lower()] = stem
                        break
        except OSError:
            pass
    return names


class Blocked(Exception):
    def __init__(self, reason, advice):
        super().__init__(reason)
        self.reason = reason
        self.advice = advice


def route(entry):
    return "Use %s instead (status, then next, then next --run). See scripts/ops/README.md." % entry


# ---------------------------------------------------------------- splitting

HEREDOC_RE = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def strip_heredocs(cmd):
    """Return (command without heredoc bodies, concatenated bodies)."""
    lines = cmd.split("\n")
    out, bodies, i = [], [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        pending = [(m.group(2), m.group(0).startswith("<<-")) for m in HEREDOC_RE.finditer(line)]
        i += 1
        for delim, dash in pending:
            while i < len(lines):
                body = lines[i]
                i += 1
                if (body.lstrip("\t") if dash else body) == delim:
                    break
                bodies.append(body)
    return "\n".join(out), "\n".join(bodies)


def grab_paren(s, i):
    """s[i:] starts just after "$(" ; return (inner, index after the closing paren)."""
    depth, j, q = 1, i, None
    while j < len(s):
        c = s[j]
        if q:
            if c == "\\" and q == '"':
                j += 2
                continue
            if c == q:
                q = None
        elif c in "'\"":
            q = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return s[i:j], j + 1
        j += 1
    return s[i:], len(s)


def segments(cmd):
    """Split a command line into simple-command strings."""
    out, subs, cur = [], [], []
    i, n, q = 0, len(cmd), None

    def flush():
        text = "".join(cur).strip()
        if text:
            out.append(text)
        del cur[:]

    while i < n:
        c = cmd[i]
        if q == "'":
            cur.append(c)
            if c == "'":
                q = None
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            cur.append(cmd[i:i + 2])
            i += 2
            continue
        if c == "$" and cmd[i + 1:i + 2] == "(":
            inner, j = grab_paren(cmd, i + 2)
            subs.append(inner)
            cur.append(" ")
            i = j
            continue
        if c == "`":
            j = cmd.find("`", i + 1)
            j = n if j < 0 else j
            subs.append(cmd[i + 1:j])
            cur.append(" ")
            i = j + 1
            continue
        if q == '"':
            cur.append(c)
            if c == '"':
                q = None
            i += 1
            continue
        if c in "'\"":
            q = c
            cur.append(c)
            i += 1
            continue
        if c == "#" and (not cur or cur[-1] in " \t"):
            j = cmd.find("\n", i)
            i = n if j < 0 else j
            continue
        if c in ";&|\n()":
            flush()
            i += 1
            continue
        cur.append(c)
        i += 1
    flush()
    for s in subs:
        out.extend(segments(s))
    return out


def words(segment):
    try:
        return shlex.split(segment, comments=False, posix=True)
    except ValueError:
        return segment.split()


# ---------------------------------------------------------------- resolving

ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
MARKER = "MACPROVIDER_OPS_ENTRYPOINT"


def check_assignment(tok):
    if tok.startswith(MARKER + "="):
        raise Blocked("the entry-point marker is set by scripts/ops only, never by hand",
                      route("scripts/ops/<train>.sh"))


def skip_options(toks, i, with_arg):
    while i < len(toks) and toks[i].startswith("-") and toks[i] != "-":
        if toks[i] == "--":
            return i + 1
        i += 2 if (toks[i] in with_arg and "=" not in toks[i]) else 1
    return i


def reparse(text, depth):
    """Parse a wrapped command string (bash -c, ssh, su -c, watch...) again."""
    for sub in segments(text):
        yield from simple_commands(sub, depth + 1)


def simple_commands(segment, depth=0):
    """Yield (word_basename, raw_word, args) for a segment, unwrapping wrappers."""
    if depth > 8:
        return
    toks = words(segment)
    i = 0
    while i < len(toks) and ASSIGN_RE.match(toks[i]):
        check_assignment(toks[i])
        i += 1
    while i < len(toks):
        w = os.path.basename(toks[i])
        if w == "sudo":
            i = skip_options(toks, i + 1, {"-u", "-g", "-C", "-h", "-p", "-U", "-r", "-t", "-D", "-R", "-T"})
        elif w == "env":
            i += 1
            while i < len(toks) and (toks[i].startswith("-") or ASSIGN_RE.match(toks[i])):
                check_assignment(toks[i])
                if toks[i] in ("-S", "--split-string"):
                    for sub in segments(" ".join(toks[i + 1:])):
                        yield from simple_commands(sub, depth + 1)
                    return
                i += 2 if toks[i] in ("-u", "--unset", "-C", "--chdir") else 1
        elif w in ("nohup", "time", "command", "exec", "builtin", "stdbuf", "caffeinate", "chronic"):
            i = skip_options(toks, i + 1, {"-o", "-e", "-i"})
        elif w == "nice":
            i = skip_options(toks, i + 1, {"-n"})
        elif w == "ionice":
            i = skip_options(toks, i + 1, {"-c", "-n", "-p", "-P", "-u"})
        elif w == "timeout":
            i = skip_options(toks, i + 1, {"-s", "-k", "--signal", "--kill-after"}) + 1
        elif w == "xargs":
            i = skip_options(toks, i + 1, {"-n", "-I", "-L", "-P", "-s", "-d", "-E", "-a"})
        elif w == "systemd-run":
            i = skip_options(toks, i + 1, {"-p", "--property", "-u", "--unit", "-E", "--setenv",
                                           "--uid", "--gid", "-M", "--machine", "-H", "--host",
                                           "--description", "--slice", "--on-calendar"})
        elif w in ("export", "declare", "typeset", "readonly", "local"):
            for tok in toks[i + 1:]:
                check_assignment(tok)
            return
        elif w == "eval":
            for sub in segments(" ".join(toks[i + 1:])):
                yield from simple_commands(sub, depth + 1)
            return
        elif w in ("bash", "sh", "zsh", "dash", "ksh"):
            i += 1
            syntax_only = False
            while i < len(toks) and toks[i][:1] in "-+" and toks[i] not in ("-", "+"):
                tok = toks[i]
                if tok == "--":
                    i += 1
                    break
                if tok in ("-o", "+o"):
                    i += 2
                    continue
                if tok.startswith("--"):
                    i += 1
                    continue
                if "c" in tok[1:] and i + 1 < len(toks):
                    for sub in segments(toks[i + 1]):
                        yield from simple_commands(sub, depth + 1)
                    return
                if "n" in tok[1:]:
                    syntax_only = True
                i += 1
            if syntax_only or i >= len(toks):
                return
            yield os.path.basename(toks[i]), toks[i], toks[i + 1:]
            return
        elif w == "ssh":
            i = skip_options(toks, i + 1, {"-%s" % c for c in "BbcDEeFIiJLlmOoPpQRSWw"})
            rest = toks[i + 1:]
            if rest[:1] == ["--"]:
                rest = rest[1:]
            if rest:
                yield from reparse(" ".join(rest), depth)
            return
        elif w == "flock":
            # flock [opts] LOCK (-c PAYLOAD | COMMAND...)
            i = skip_options(toks, i + 1, {"-E", "-w", "--conflict-exit-code", "--timeout"}) + 1
            if i < len(toks) and toks[i] in ("-c", "--command"):
                if i + 1 < len(toks):
                    yield from reparse(toks[i + 1], depth)
                return
        elif w in ("su", "runuser"):
            payload = flag_values(toks[i + 1:], {"-c", "--command"})
            for p in payload:
                yield from reparse(p, depth)
            return
        elif w == "doas":
            i = skip_options(toks, i + 1, {"-u", "-C"})
        elif w == "setsid":
            i = skip_options(toks, i + 1, set())
        elif w == "watch":
            # watch runs its arguments through sh -c unless -x; parse them either way.
            i = skip_options(toks, i + 1, {"-n", "--interval", "-q", "--equexit"})
            if i < len(toks):
                yield from reparse(" ".join(toks[i:]), depth)
            return
        elif w == "script":
            for p in flag_values(toks[i + 1:], {"-c", "--command"}):
                yield from reparse(p, depth)
            return
        elif w == "chroot":
            i = skip_options(toks, i + 1, {"--userspec", "--groups"}) + 1
        elif w in ("source", "."):
            if i + 1 < len(toks):
                yield os.path.basename(toks[i + 1]), toks[i + 1], toks[i + 2:]
            return
        else:
            break
    if i < len(toks):
        yield os.path.basename(toks[i]), toks[i], toks[i + 1:]


# ---------------------------------------------------------------- rules

def positional_after(args, value_flags):
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            return args[i + 1] if i + 1 < len(args) else None
        if a.startswith("-"):
            i += 2 if (a in value_flags and "=" not in a) else 1
            continue
        return a
    return None


def guard_workflow(ref, names):
    if ref is None:
        return
    if "$" in ref or "`" in ref:
        raise Blocked("workflow named through a shell expansion (%s) cannot be checked" % ref,
                      "Dispatch by literal workflow file name through the scripts/ops entry points.")
    base = os.path.basename(ref)
    stem = re.sub(r"\.ya?ml$", "", base)
    if stem in WORKFLOWS and base != stem:
        raise Blocked("direct dispatch of %s" % base, route(WORKFLOWS[stem]))
    if ref.strip().lower() in names:
        stem = names[ref.strip().lower()]
        raise Blocked("direct dispatch of %s by display name" % stem, route(WORKFLOWS[stem]))
    if ref.isdigit():
        raise Blocked("dispatch by numeric workflow id %s cannot be checked" % ref,
                      "Dispatch by workflow file name through the scripts/ops entry points.")


GH_GLOBAL = {"-R", "--repo"}
GH_RUN_FLAGS = {"-f", "-F", "--field", "--raw-field", "-r", "--ref", "-R", "--repo", "--json"}
GIT_GLOBAL = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
RESTART_VERBS = {"restart", "try-restart", "reload-or-restart", "try-reload-or-restart"}


def classify(word, raw, args, names, ctx):
    if word == "gh":
        a = args[skip_options(args, 0, GH_GLOBAL):]
        if a[:2] == ["workflow", "run"]:
            guard_workflow(positional_after(a[2:], GH_RUN_FLAGS), names)
        elif a[:1] == ["api"]:
            for tok in a[1:]:
                m = re.search(r"/workflows/([^/\s]+)/dispatches", tok)
                if m:
                    guard_workflow(m.group(1), names)
        elif a[:2] == ["run", "rerun"]:
            raise Blocked("gh run rerun re-dispatches a release or deploy run",
                          "Use the scripts/ops entry points; they dispatch fresh runs in runbook order.")
        elif a[:1] == ["pr"] and a[1:2] and a[1] in ("create", "edit", "merge"):
            ctx["message_files"].extend(flag_values(a[2:], {"--body-file", "-F"}))
            ctx["message"] = True
    elif word == "git":
        i = skip_options(args, 0, GIT_GLOBAL)
        if args[i:i + 1] == ["commit"]:
            ctx["message_files"].extend(flag_values(args[i + 1:], {"-F", "--file"}))
            ctx["message"] = True
    elif word == "deploy-pearl-vps.sh":
        raise Blocked("direct deploy-pearl-vps.sh", route(CAT + " (catalog) or " + RT + " (runtime)"))
    elif word == "catalog-content-release.sh" and "--deploy" in args:
        raise Blocked("direct catalog-content-release.sh --deploy", route(CAT))
    elif word == "publish-native-mtp-revocations.sh" and "--deploy" in args:
        raise Blocked("direct publish-native-mtp-revocations.sh --deploy", route(CAT))
    elif word == "macprovider-pearl-update" and "--apply" in args:
        raise Blocked("direct macprovider-pearl-update --apply", route(RT))
    elif word == "systemctl" and RESTART_VERBS & set(args) and any(
            a.startswith("macprovider-coordinator") for a in args):
        raise Blocked("direct coordinator restart", route(CAT + " or " + RT))
    elif word == "service" and args[:1] and args[0].startswith("macprovider-coordinator") and \
            RESTART_VERBS & set(args[1:]):
        raise Blocked("direct coordinator restart", route(CAT + " or " + RT))


def flag_values(args, flags):
    vals = []
    for i, a in enumerate(args):
        if a in flags and i + 1 < len(args):
            vals.append(args[i + 1])
        for f in flags:
            if f.startswith("--") and a.startswith(f + "="):
                vals.append(a.split("=", 1)[1])
    return vals


CLOSING_RE = re.compile(
    r"\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b[\s:]*\(?\s*"
    r"(([\w.-]+/[\w.-]+)?#\d+|https?://github\.com/[\w.-]+/[\w.-]+/(issues|pull)/\d+)",
    re.IGNORECASE)


def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        return 0
    if event.get("tool_name") != "Bash":
        return 0
    cmd = (event.get("tool_input") or {}).get("command") or ""
    if not cmd.strip():
        return 0
    cwd = event.get("cwd") or os.getcwd()
    names = display_names()
    body_cmd, heredocs = strip_heredocs(cmd)
    ctx = {"message": False, "message_files": []}
    try:
        for seg in segments(body_cmd):
            for word, raw, args in simple_commands(seg):
                classify(word, raw, args, names, ctx)
        if ctx["message"]:
            text = cmd + "\n" + heredocs
            for path in ctx["message_files"]:
                if path == "-":
                    continue
                try:
                    with open(os.path.join(cwd, os.path.expanduser(path)), errors="replace") as f:
                        text += "\n" + f.read(200000)
                except OSError:
                    pass
            m = CLOSING_RE.search(text)
            if m:
                raise Blocked(
                    "message contains the GitHub closing keyword \"%s\"; GitHub closes the issue on merge, "
                    "even after a negation" % m.group(0).strip(),
                    "Reference the issue without a closing keyword, for example \"Refs #N\" or \"Part of #N\".")
    except Blocked as b:
        sys.stderr.write("BLOCKED by scripts/ops/hooks/claude-pretooluse-ops-guard.sh: %s\n%s\n" % (b.reason, b.advice))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
