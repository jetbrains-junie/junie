# Junie Runner
A command-line Junie interface for running code tasks.

## Usage

``` bash
junie [<options>] [<task>]

# Examples
junie "Fix the bug in MyClass"
junie "Finish the sum function in the MyFile.kt" -p ./my-project
```

## Arguments

| Argument | Description |
| --- | --- |
| `<task>` | Task description (optional positional argument) |

## Options

### Core Options

| Option | Description                                                       |
| --- |-------------------------------------------------------------------|
| `--task=<text>` | Task description (alternative to positional argument)             |
| `-f, --file=<text>` | Path to the JSON task file                                        |
| `-p, --project=<text>` | Project directory to run Junie (default is the current directory) |
| `--ide=<text>` | IDE + Version (e.g., `IdeaUltimate 2025.1`), IDEA Ultimate 2025.1 is default|

### Authentication Options

| Option | Description |
| --- | --- |
| `-a, --auth=<text>` | Authentication token (optional, fallbacks to JBA authentication) |

### Supported Token Formats
- **GitHub tokens**: `ghp_*` or `github_pat_*`
- **Ingrazzio tokens**: `igz_*` or contains "ingrazzio"

### GitHub Options

| Option | Description | Example |
| --- | --- | --- |
| `-g, --github-url=<value>` | Any GitHub URL for an issue, PR, CI or comment | `--github-url "https://github.com/user/repo/pull/1#pullrequestreview-123"` |
| `--github-issue=<value>` | GitHub issue URL | `--github-issue "https://github.com/owner/repo/issues/12" |
| `--github-pr-review=<value>` | GitHub PR review URL | `--github-pr-review "https://github.com/owner/repo/pull/456#pullrequestreview-123"` |
| `--github-issue-comment=<value>` | GitHub PR comment URL | `--github-issue-comment "https://github.com/owner/repo/issues/12#issuecomment-456"` |
| `--github-fix-ci=<value>` | GitHub CI check URL |  |

> **Note**: GitHub URLs containing fragments (#) must be quoted to prevent shell interpretation.
### System Options

| Option | Description |
| --- | --- |
| `-t, --timeout=<int>` | Time limit in milliseconds |
| `-c, --cache-dir=<text>` | Caching directory for agent and IDE |
| `--version` | Show version |
| `-h, --help` | Show help message and exit |


## Important Notes
- **GitHub URLs**: URLs containing fragments (#) must be quoted to prevent shell interpretation
- **Authentication**: Auto-detected based on token format
- **Fallback Authentication**: If no authentication is provided, JBA (JetBrains Account) login will be attempted
- **GitHub Commands**: GitHub commands are mutually exclusive - use only one at a time