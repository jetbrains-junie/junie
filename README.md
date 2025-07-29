# Junie Runner
A command-line Junie interface for running code tasks.

## Usage

``` bash
junie [<options>] [<task>]
```

Quick start example

``` bash
cd you-project-folder
junie "Fix the bug in MyClass"
```

Or run Junie from your terminal in any other place

```bash
junie "Finish the sum function in the MyFile.kt" -p /path/to/project
```

## Arguments

| Argument | Description |
| --- | --- |
| `<task>` | Task description (optional positional argument) |

## Options

### Core Options


| Option | Description                                                       |
| --- |-------------------------------------------------------------------|
| `--task=<text>` | Task description (alternative to positional argument)             |                                  |
| `-p, --project=<text>` | Project directory to run Junie (default is the current directory) |
| `--ide=<text>` | IDE + Version (e.g., `IdeaUltimate 2025.1.2`), IDEA Ultimate 2025.1 is default|

### Authentication Options

| Option | Description |
| --- | --- |
| `-a, --auth=<text>` | Authentication token (optional, fallbacks to JBA authentication) |

### Supported Token Formats
- **GitHub tokens**: `ghp_*` or `github_pat_*`
- **Ingrazzio tokens**

### GitHub Options

| Option | Description | Example |
| --- | --- | --- |
| `-g, --github-url=<value>` | Any GitHub URL for an issue, PR, CI or comment | `--github-url "https://github.com/user/repo/pull/1#pullrequestreview-123"` |
| `--github-issue=<value>` | GitHub issue URL | `--github-issue "https://github.com/owner/repo/issues/12"` |
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

## Environment Variables Configuration

You can configure Junie Runner using environment variables instead of command-line options. This is particularly useful for **CI/CD environments** and automated deployments.

### Available Environment Variables

| Environment Variable | Equivalent Option | Description |
| --- | --- | --- |
| `PROJECT` | `-p, --project` | Project directory to run Junie |
| `ENV_TIME_LIMIT` | `-t, --timeout` | Time limit in milliseconds |
| `FOLDER_WORK` | `-c, --cache-dir` | Caching directory for agent and IDE |

### CI/CD Script Example

``` bash
# Set environment variables for Junie configuration
export PROJECT="/workspace/my-project" 
export ENV_TIME_LIMIT="300000" # 5 minutes timeout
export FOLDER_WORK="/tmp/junie-cache"

junie "Review and fix any code quality issues in the latest commit"
```

## Important Notes
- **GitHub URLs**: URLs containing fragments (#) must be quoted to prevent shell interpretation
- **Authentication**: Auto-detected based on token format
- **Fallback Authentication**: If no authentication is provided, JBA (JetBrains Account) login will be attempted
- **GitHub Commands**: GitHub commands are mutually exclusive - use only one at a time
