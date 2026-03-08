<#
.SYNOPSIS
Shared helpers for task clarification policy defaults and resolution.

.DESCRIPTION
Centralizes the new clarification policy concept so task creation, runtime
analysis, and UI/state readers use the same precedence rules.
#>

function Get-ValidClarificationPolicies {
    return @('off', 'balanced', 'strict', 'required')
}

function Get-ClarificationPolicyProjectRoot {
    param(
        [string]$ProjectRoot
    )

    if ($ProjectRoot) {
        return $ProjectRoot
    }

    if ($global:DotbotProjectRoot) {
        return $global:DotbotProjectRoot
    }

    $cursor = $PSScriptRoot
    while ($cursor) {
        if ((Split-Path -Leaf $cursor) -eq ".bot") {
            return (Split-Path -Parent $cursor)
        }

        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) {
            break
        }
        $cursor = $parent
    }

    throw "Dotbot project root could not be resolved"
}

function Get-TaskFieldValue {
    param(
        [Parameter(Mandatory)] [object]$Task,
        [Parameter(Mandatory)] [string]$FieldName
    )

    if ($Task -is [System.Collections.IDictionary]) {
        return $Task[$FieldName]
    }

    if ($Task.PSObject.Properties[$FieldName]) {
        return $Task.$FieldName
    }

    return $null
}

function Test-TaskHasField {
    param(
        [Parameter(Mandatory)] [object]$Task,
        [Parameter(Mandatory)] [string]$FieldName
    )

    if ($Task -is [System.Collections.IDictionary]) {
        return $Task.Contains($FieldName)
    }

    return $Task.PSObject.Properties.Match($FieldName).Count -gt 0
}

function Normalize-ClarificationPolicy {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Policy
    )

    if ($null -eq $Policy) {
        return $null
    }

    $normalized = "$Policy".Trim().ToLowerInvariant()
    if (-not $normalized) {
        return $null
    }

    if ($normalized -in (Get-ValidClarificationPolicies)) {
        return $normalized
    }

    throw "Invalid clarification_policy '$Policy'. Valid values: $((Get-ValidClarificationPolicies) -join ', ')"
}

function Get-DefaultNewTaskClarificationPolicy {
    param(
        [string]$ProjectRoot,
        [string]$SettingsPath
    )

    $resolvedSettingsPath = $SettingsPath
    if (-not $resolvedSettingsPath) {
        $resolvedProjectRoot = Get-ClarificationPolicyProjectRoot -ProjectRoot $ProjectRoot
        $resolvedSettingsPath = Join-Path $resolvedProjectRoot ".bot\defaults\settings.default.json"
    }

    $fallback = 'balanced'
    if (-not (Test-Path $resolvedSettingsPath)) {
        return $fallback
    }

    try {
        $settings = Get-Content $resolvedSettingsPath -Raw | ConvertFrom-Json
        $configured = $settings.analysis?.default_new_task_clarification_policy
        $normalized = Normalize-ClarificationPolicy -Policy $configured
        if ($normalized) {
            return $normalized
        }
    } catch {
        # Fall back to the default if settings are missing or malformed.
    }

    return $fallback
}

function Resolve-NewTaskClarificationPolicy {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$RequestedPolicy,

        [bool]$NeedsInterview = $false,

        [string]$ProjectRoot,
        [string]$SettingsPath
    )

    $normalizedRequested = Normalize-ClarificationPolicy -Policy $RequestedPolicy
    if ($normalizedRequested) {
        return $normalizedRequested
    }

    if ($NeedsInterview) {
        return 'required'
    }

    return (Get-DefaultNewTaskClarificationPolicy -ProjectRoot $ProjectRoot -SettingsPath $SettingsPath)
}

function Get-EffectiveTaskClarificationPolicy {
    param(
        [Parameter(Mandatory)]
        [object]$Task
    )

    $normalizedRequested = Normalize-ClarificationPolicy -Policy (Get-TaskFieldValue -Task $Task -FieldName 'clarification_policy')
    if ($normalizedRequested) {
        return $normalizedRequested
    }

    $needsInterview = Get-TaskFieldValue -Task $Task -FieldName 'needs_interview'
    if ($needsInterview -eq $true) {
        return 'required'
    }

    return 'legacy'
}

function Get-LegacyNeedsInterviewFlag {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$ClarificationPolicy
    )

    if ($null -eq $ClarificationPolicy) {
        return $false
    }

    $policyText = "$ClarificationPolicy".Trim().ToLowerInvariant()
    if (-not $policyText -or $policyText -eq 'legacy') {
        return $false
    }

    return (Normalize-ClarificationPolicy -Policy $policyText) -eq 'required'
}

function Get-AnalysisPromptNeedsInterviewFlag {
    param(
        [Parameter(Mandatory)]
        [object]$Task
    )

    if (Test-TaskClarificationSatisfied -Task $Task) {
        return $false
    }

    $effectivePolicy = Get-EffectiveTaskClarificationPolicy -Task $Task
    return Get-LegacyNeedsInterviewFlag -ClarificationPolicy $effectivePolicy
}

function Test-TaskClarificationSatisfied {
    param(
        [Parameter(Mandatory)]
        [object]$Task
    )

    $hasClarificationResolved = $false
    if (Test-TaskHasField -Task $Task -FieldName 'questions_resolved') {
        $resolvedQuestions = @(Get-TaskFieldValue -Task $Task -FieldName 'questions_resolved')
        foreach ($resolvedQuestion in $resolvedQuestions) {
            $questionKind = Normalize-ClarificationPolicyMarker -Value (Get-TaskFieldValue -Task $resolvedQuestion -FieldName 'kind')
            if ($questionKind -eq 'clarification') {
                $hasClarificationResolved = $true
                break
            }

            $questionId = Get-TaskFieldValue -Task $resolvedQuestion -FieldName 'id'
            if ("$questionId" -match '^q\d+$') {
                $hasClarificationResolved = $true
                break
            }
        }
    }
    $pendingQuestion = Get-TaskFieldValue -Task $Task -FieldName 'pending_question'
    $hasPending = $null -ne $pendingQuestion

    return ($hasClarificationResolved -and -not $hasPending)
}

function Normalize-ClarificationPolicyMarker {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $normalized = "$Value".Trim().ToLowerInvariant()
    if (-not $normalized) {
        return $null
    }

    return $normalized
}

function Test-ShouldRunClarificationGate {
    param(
        [Parameter(Mandatory)]
        [object]$Task
    )

    $effectivePolicy = Get-EffectiveTaskClarificationPolicy -Task $Task
    if ($effectivePolicy -notin @('balanced', 'strict', 'required')) {
        return $false
    }

    if (Test-TaskClarificationSatisfied -Task $Task) {
        return $false
    }

    return $true
}

Export-ModuleMember -Function @(
    'Get-ValidClarificationPolicies',
    'Normalize-ClarificationPolicy',
    'Get-DefaultNewTaskClarificationPolicy',
    'Resolve-NewTaskClarificationPolicy',
    'Get-EffectiveTaskClarificationPolicy',
    'Get-LegacyNeedsInterviewFlag',
    'Get-AnalysisPromptNeedsInterviewFlag',
    'Test-TaskClarificationSatisfied',
    'Test-ShouldRunClarificationGate'
)
