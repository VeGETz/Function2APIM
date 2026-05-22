# Function2APIM

> **⚠️ AI-Generated Code — Use with CARE**
> This project was 100% coded by AI (Claude by Anthropic). It has been tested in a real Azure environment but may contain bugs or edge cases. Review the script before running in production. You are responsible for any changes made to your APIM instance.



PowerShell script to sync Azure Functions (.NET Isolated) with Azure API Management operations — keeps APIM in sync as you add, change, or remove functions during development.

## Problem

APIM only auto-imports Function App operations at initial link time. Functions added later are ignored and require manual registration in APIM.

## What it does

1. Recursively scans your Function App `.cs` files for `[Function]` + `[HttpTrigger]` attributes
2. Fetches all existing operations from your APIM API
3. Diffs local functions vs APIM operations
4. Creates new, updates changed, and optionally deletes stale operations

## Requirements

- PowerShell 5.1+
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az login` already done)
- .NET Isolated Azure Functions project (C#)

## Setup

1. Copy the example config and fill in your values:
   ```
   cp apim-sync.config.example.json apim-sync.config.json
   ```

2. Edit `apim-sync.config.json`:
   ```json
   {
     "subscriptionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
     "resourceGroup": "my-resource-group",
     "apimInstance": "my-apim-instance",
     "apiId": "my-function-api",
     "backendId": "my-backend-id"
   }
   ```
   > `apim-sync.config.json` is gitignored — never commit it.

   Alternatively, omit the file and the script will prompt for each value on first run and offer to save.

## Usage

```powershell
# Show help
.\Sync-FunctionToApim.ps1

# Preview changes (no writes to APIM)
.\Sync-FunctionToApim.ps1 -DryRun

# Preview with explicit project path
.\Sync-FunctionToApim.ps1 -DryRun -ProjectPath "C:\Projects\MyFunctionApp"

# Apply creates and updates
.\Sync-FunctionToApim.ps1 -Apply

# Apply and remove stale operations from APIM
.\Sync-FunctionToApim.ps1 -Apply -Prune
```

## Flags

| Flag | Description |
|---|---|
| `-DryRun` | Show diff only, no changes made |
| `-Apply` | Apply creates and updates to APIM |
| `-Prune` | (with `-Apply`) also delete APIM operations not found in code |
| `-ProjectPath` | Path to Function App project root (default: current directory) |

## How operations are named

| Concept | Format | Example |
|---|---|---|
| Operation ID | `{method}-{functionname}` (lowercase) | `get-listorders` |
| Display name | Exact function name | `ListOrders` |
| URL template | From `Route =` parameter, or function name if absent | `/orders/{id}` |

- Multi-method functions (e.g. `"get", "post"`) produce one APIM operation per method
- Route constraints are stripped: `{id:guid}` becomes `{id}`
- Non-HTTP triggers (Timer, Queue, etc.) are skipped and logged

## Policy

On operation **create**, the following policy is applied automatically using the configured `backendId`:

```xml
<policies>
  <inbound>
    <base />
    <set-backend-service id="apim-generated-policy" backend-id="{backendId}" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
```

Policy is **not overwritten** on updates — manual policy edits in APIM are preserved.

## License

MIT License — see [LICENSE](LICENSE) for details.

## Diff output

```
[+] CREATE   — function exists in code, missing from APIM
[~] UPDATE   — operation exists but route or method changed
[-] STALE    — operation in APIM not found in code (deleted with -Prune)
[=] UNCHANGED — already in sync
```
