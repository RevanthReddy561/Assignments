"""Generate a read-only Markdown change report from a local Git repository.

Example:
  python generate_change_report.py --repo C:\\GitHub\\abbvie-intelligence-api --base 46f8f82 --head a7269ea
"""
import argparse
import re
import subprocess
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


def git(repo, *args):
    """Run Git in the selected repository, independent of script location."""
    return subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True,
        text=True, encoding="utf-8", errors="replace", check=True
    ).stdout


def get_commits(repo, base, head):
    """Read commits in the range (base excluded, head included)."""
    output = git(repo, "log", f"{base}..{head}",
                 "--format=%h%x09%aI%x09%an%x09%s")
    return [line.split("\t", 3) for line in output.splitlines() if line]


def get_changes(repo, base, head):
    """Compare endpoint trees, including changes brought in by merges."""
    output = git(repo, "diff", "--name-status", "-M", base, head)
    changes = []
    for line in output.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            changes.append((parts[0], parts[-1]))
    return changes


def categorize(path):
    """Estimate an affected component using file-path conventions."""
    name = path.lower()
    if "test" in name:
        return "Tests"
    if any(term in name for term in ("worker", "queue", "redis")):
        return "Background Workers"
    if any(term in name for term in ("router", "skill", "agent")):
        return "Router / Agents"
    if any(term in name for term in ("config", ".yaml", ".yml", ".env")):
        return "Configuration"
    if any(term in name for term in ("api", "endpoint", "route")):
        return "Backend API"
    return "Other"


def analyze_diff(repo, base, head):
    """Count Python line edits and detect added/removed function definitions."""
    diff = git(repo, "diff", "--unified=0", base, head, "--", "*.py")
    functions, added, removed = set(), 0, 0
    for line in diff.splitlines():
        if line.startswith(("+++", "---")):
            continue
        if line.startswith(("+", "-")):
            added += line.startswith("+")
            removed += line.startswith("-")
            match = re.match(r"[+-]\s*(?:async\s+)?def\s+(\w+)", line)
            if match:
                functions.add(match.group(1))
    return sorted(functions), added, removed


def generate_report(repo, base, head, commits, changes, analysis):
    """Build Markdown with verified Git evidence and explicit limitations."""
    functions, added, removed = analysis
    groups = Counter(categorize(path) for _, path in changes)
    lines = [
        "# Code Change Analysis Report", "",
        f"Generated (UTC): {datetime.now(timezone.utc):%Y-%m-%d %H:%M}",
        f"Repository: `{repo}`", f"Range: `{base}` → `{head}`", "",
        "## Summary", f"- Commits: {len(commits)}",
        f"- Changed files: {len(changes)}",
        f"- Python lines added: {added}; removed: {removed}", "",
        "## Affected Components",
        *([f"- {name}: {count} file(s)" for name, count in sorted(groups.items())]
          or ["- No net file changes"]), "", "## Commit History",
        *([f"- `{sha}` | {date} | {author} | {message}"
           for sha, date, author, message in commits] or ["- No commits"]),
        "", "## Changed Files",
        *([f"- `{status}` | `{path}` | {categorize(path)}"
           for status, path in changes] or ["- No net file changes"]),
        "", "## Added/Removed Python Function Definitions",
        *([f"- `{name}()`" for name in functions]
          or ["- No added or removed definitions detected"]),
        "", "## Testing Considerations",
        "- Review changes in affected components and their related tests.",
        "- Validate configuration changes and relevant integrations in QA.",
        "- Confirm required testing evidence before production promotion.",
        "", "## Limitations",
        "- This is a change inventory, not AI-generated semantic analysis.",
        "- Function-body changes are not mapped to enclosing functions.",
        "- Component names are inferred from paths; testing is not verified.",
        "- File changes are net differences between the two endpoints.",
    ]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd(),
                        help="Local Git repository path (default: current directory)")
    parser.add_argument("--base", required=True, help="Older commit SHA or ref")
    parser.add_argument("--head", required=True, help="Newer commit SHA or ref")
    parser.add_argument("--output", type=Path, default=Path("goai-change-report.md"))
    args = parser.parse_args()
    try:
        repo = args.repo.expanduser().resolve()
        git(repo, "rev-parse", "--is-inside-work-tree")
        commits = get_commits(repo, args.base, args.head)
        changes = get_changes(repo, args.base, args.head)
        analysis = analyze_diff(repo, args.base, args.head)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            generate_report(repo, args.base, args.head, commits, changes, analysis),
            encoding="utf-8"
        )
        print(f"Report generated: {args.output.resolve()}")
        print(f"Commits: {len(commits)} | Changed files: {len(changes)}")
    except (OSError, subprocess.CalledProcessError) as exc:
        details = exc.stderr.strip() if isinstance(exc, subprocess.CalledProcessError) and exc.stderr else str(exc)
        parser.exit(1, f"Error: {details}\n")


if __name__ == "__main__":
    main()
