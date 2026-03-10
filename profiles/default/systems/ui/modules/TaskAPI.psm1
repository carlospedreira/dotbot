<#
.SYNOPSIS
Task management API module

.DESCRIPTION
Provides task plan viewing, action-required listing, question answering,
split approval, task creation, and audited roadmap task mutations.
Extracted from server.ps1 for modularity.
#>

$script:Config = @{
    BotRoot = $null
    ProjectRoot = $null
}

function Initialize-TaskAPI {
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$ProjectRoot
    )
    $script:Config.BotRoot = $BotRoot
    $script:Config.ProjectRoot = $ProjectRoot

    # Save MCP tool script paths for on-demand dot-sourcing at call sites
    # (dot-sourcing inside a function scopes the definitions to that function only)
    $script:TaskAnswerQuestionScript = "$BotRoot\systems\mcp\tools\task-answer-question\script.ps1"
    $script:TaskApproveSplitScript = "$BotRoot\systems\mcp\tools\task-approve-split\script.ps1"
    $script:TaskMutationModulePath = "$BotRoot\systems\mcp\modules\TaskMutation.psm1"
}

function Get-TasksBaseDir {
    return (Join-Path $script:Config.BotRoot "workspace\tasks")
}

function Import-TaskMutationModule {
    if (-not (Test-Path $script:TaskMutationModulePath)) {
        throw "TaskMutation module was not found: $($script:TaskMutationModulePath)"
    }

    if (-not (Get-Command Set-TaskIgnoreState -ErrorAction SilentlyContinue)) {
        Import-Module $script:TaskMutationModulePath -Global -Force | Out-Null
    }
}

function Get-TaskMutationActor {
    param(
        [string]$Actor
    )

    if ($Actor) {
        return $Actor
    }

    $settingsPath = Join-Path $script:Config.BotRoot "defaults\settings.default.json"
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
            if ($settings.profile) {
                return "ui:$($settings.profile)"
            }
        } catch {
            # Fall through to environment defaults
        }
    }

    if ($env:USERNAME) {
        return "ui:$($env:USERNAME)"
    }

    return "ui"
}

function Test-IsTaskApiObjectRecord {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return $true
    }

    if ($Value -is [string] -or $Value -is [char] -or $Value -is [ValueType]) {
        return $false
    }

    return ($Value.GetType().Name -eq 'PSCustomObject')
}

function ConvertTo-TaskApiHashtable {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return @{}
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $hash = @{}
        foreach ($key in $InputObject.Keys) {
            $hash[$key] = ConvertTo-TaskApiValue -Value $InputObject[$key]
        }
        return $hash
    }

    if (Test-IsTaskApiObjectRecord -Value $InputObject) {
        $hash = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $hash[$property.Name] = ConvertTo-TaskApiValue -Value $property.Value
        }
        return $hash
    }

    throw "Updates must be a JSON object"
}

function ConvertTo-TaskApiValue {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string] -or $Value -is [char] -or $Value -is [ValueType]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return ConvertTo-TaskApiHashtable -InputObject $Value
    }

    if (Test-IsTaskApiObjectRecord -Value $Value) {
        return ConvertTo-TaskApiHashtable -InputObject $Value
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { ConvertTo-TaskApiValue -Value $_ })
    }

    return $Value
}

function Get-TodoTaskRecord {
    param(
        [Parameter(Mandatory)] [string]$TaskId
    )

    $todoDir = Join-Path (Get-TasksBaseDir) "todo"
    if (-not (Test-Path $todoDir)) {
        return $null
    }

    foreach ($file in @(Get-ChildItem -Path $todoDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        try {
            $task = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
            if ($task.id -eq $TaskId) {
                return @{
                    task = $task
                    path = $file.FullName
                    name = $file.Name
                }
            }
        } catch {
            # Ignore malformed files while scanning
        }
    }

    return $null
}

function Get-DeletedArchiveVersions {
    param(
        [string]$TaskId
    )

    $deletedDir = Join-Path (Join-Path (Get-TasksBaseDir) "todo") "deleted_tasks"
    if (-not (Test-Path $deletedDir)) {
        return @()
    }

    $versions = @()
    foreach ($file in @(Get-ChildItem -Path $deletedDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        try {
            $archive = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
            if (-not $TaskId -or $archive.task_id -eq $TaskId) {
                $versions += $archive
            }
        } catch {
            # Ignore malformed archive files while scanning
        }
    }

    return @(
        $versions |
            Sort-Object {
                try {
                    if ($_.captured_at) { [DateTime]$_.captured_at } else { [DateTime]::MinValue }
                } catch {
                    [DateTime]::MinValue
                }
            } -Descending
    )
}

function Get-ActiveTodoTaskIds {
    $taskIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $todoDir = Join-Path (Get-TasksBaseDir) "todo"
    if (-not (Test-Path $todoDir)) {
        return $taskIds
    }

    foreach ($file in @(Get-ChildItem -Path $todoDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        try {
            $task = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
            if ($task.id) {
                $taskIds.Add([string]$task.id) | Out-Null
            }
        } catch {
            # Ignore malformed task files while scanning
        }
    }

    return $taskIds
}

function Add-DeletedArchiveRestoreState {
    param(
        [Parameter(Mandatory)] [object]$Version,
        [Parameter(Mandatory)] [object]$ActiveTaskIds
    )

    $annotated = [ordered]@{}
    foreach ($property in $Version.PSObject.Properties) {
        $annotated[$property.Name] = $property.Value
    }

    $taskId = if ($Version.task_id) { [string]$Version.task_id } else { $null }
    $annotated.is_restored = ($taskId -and $ActiveTaskIds.Contains($taskId))

    return [pscustomobject]$annotated
}

function Get-TaskPlan {
    param(
        [Parameter(Mandatory)] [string]$TaskId
    )
    $botRoot = $script:Config.BotRoot
    $projectRoot = $script:Config.ProjectRoot

    # Search for task file by ID
    $tasksDir = Join-Path $botRoot "workspace\tasks"
    $statusDirs = @('todo', 'in-progress', 'done', 'skipped', 'cancelled')
    $task = $null

    foreach ($status in $statusDirs) {
        $statusDir = Join-Path $tasksDir $status
        if (Test-Path $statusDir) {
            $files = Get-ChildItem -Path $statusDir -Filter "*.json" -ErrorAction SilentlyContinue
            foreach ($file in $files) {
                try {
                    $taskContent = Get-Content $file.FullName -Raw | ConvertFrom-Json
                    if ($taskContent.id -eq $TaskId) {
                        $task = $taskContent
                        break
                    }
                } catch {
                    # Skip malformed files
                }
            }
            if ($task) { break }
        }
    }

    if (-not $task) {
        return @{
            _statusCode = 404
            success = $false
            has_plan = $false
            error = "Task not found: $TaskId"
        }
    } elseif (-not $task.plan_path) {
        return @{
            success = $true
            has_plan = $false
            task_name = $task.name
        }
    } else {
        # Resolve plan path (relative to project root)
        $planFullPath = Join-Path $projectRoot $task.plan_path

        if (-not (Test-Path $planFullPath)) {
            return @{
                success = $true
                has_plan = $false
                task_name = $task.name
                error = "Plan file not found"
            }
        } else {
            $planContent = Get-Content $planFullPath -Raw
            return @{
                success = $true
                has_plan = $true
                task_name = $task.name
                content = $planContent
            }
        }
    }
}

function Get-ActionRequired {
    $botRoot = $script:Config.BotRoot
    $tasksDir = Join-Path $botRoot "workspace\tasks"
    $actionItems = @()

    # Get needs-input tasks (questions)
    $needsInputDir = Join-Path $tasksDir "needs-input"
    if (Test-Path $needsInputDir) {
        $files = Get-ChildItem -Path $needsInputDir -Filter "*.json" -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            try {
                $task = Get-Content $file.FullName -Raw | ConvertFrom-Json
                if ($task.split_proposal) {
                    $actionItems += @{
                        type = "split"
                        task_id = $task.id
                        task_name = $task.name
                        split_proposal = $task.split_proposal
                        created_at = $task.updated_at
                    }
                } else {
                    $actionItems += @{
                        type = "question"
                        task_id = $task.id
                        task_name = $task.name
                        question = $task.pending_question
                        created_at = $task.updated_at
                    }
                }
            } catch { }
        }
    }

    # Scan processes for kickstart interview questions (needs-input status)
    $processesDir = Join-Path $botRoot ".control\processes"
    if (Test-Path $processesDir) {
        $procFiles = Get-ChildItem -Path $processesDir -Filter "proc-*.json" -File -ErrorAction SilentlyContinue
        foreach ($pf in $procFiles) {
            try {
                $proc = Get-Content $pf.FullName -Raw | ConvertFrom-Json
                if ($proc.status -eq 'needs-input' -and $proc.pending_questions) {
                    $actionItems += @{
                        type = "kickstart-questions"
                        process_id = $proc.id
                        description = $proc.description
                        questions = $proc.pending_questions
                        interview_round = $proc.interview_round
                        created_at = $proc.last_heartbeat
                    }
                }
            } catch { }
        }
    }

    return @{
        success = $true
        items = $actionItems
        count = $actionItems.Count
    }
}

function Submit-TaskAnswer {
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        $Answer,
        [string]$CustomText
    )

    # Use custom text as answer when no option selected
    if ((-not $Answer -or ($Answer -is [array] -and $Answer.Count -eq 0)) -and $CustomText) {
        $Answer = $CustomText
    }

    . $script:TaskAnswerQuestionScript
    $result = Invoke-TaskAnswerQuestion -Arguments @{
        task_id = $TaskId
        answer = $Answer
    }

    Write-Status "Answered question for task: $TaskId" -Type Success
    return $result
}

function Submit-SplitApproval {
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [bool]$Approved
    )

    . $script:TaskApproveSplitScript
    $result = Invoke-TaskApproveSplit -Arguments @{
        task_id = $TaskId
        approved = $Approved
    }

    $action = if ($Approved) { "Approved" } else { "Rejected" }
    Write-Status "$action split for task: $TaskId" -Type Success
    return $result
}

function Normalize-TaskCreationPrompt {
    param(
        [Parameter(Mandatory)] [string]$Text
    )

    $normalized = $Text -replace '\r\n?', "`n"
    $normalized = [regex]::Replace($normalized, "^\n+", "")
    $normalized = [regex]::Replace($normalized, "\n+$", "")
    return $normalized
}

function Get-TaskCreationName {
    param(
        [Parameter(Mandatory)] [string]$Prompt
    )

    $firstLine = ($Prompt -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $firstLine) {
        return "New task"
    }

    $candidate = $firstLine.Trim()
    $candidate = [regex]::Replace($candidate, '^(?:(?:[-*+]\s+(?:\[[ xX]\]\s+)?)|\[[ xX]\]\s+|\d+[.)]\s+|\[\d+\]\s+)', '')
    if ($candidate.Length -gt 72) {
        $truncated = $candidate.Substring(0, 72)
        $lastSpace = $truncated.LastIndexOf(' ')
        if ($lastSpace -gt 20) {
            $truncated = $truncated.Substring(0, $lastSpace)
        }
        $candidate = $truncated.Trim()
    }

    if (-not $candidate) {
        return "New task"
    }

    return $candidate.Substring(0,1).ToUpper() + $candidate.Substring(1)
}

function Get-TaskCreationCategory {
    param(
        [Parameter(Mandatory)] [string]$Prompt
    )

    $text = $Prompt.ToLowerInvariant()

    if ($text -match '\b(fix|bug|broken|error|issue|regression|fails?|failing|not working|doesn''?t work|does not)\b') {
        return 'bugfix'
    }

    if ($text -match '\b(ui|ux|button|modal|screen|layout|style|frontend|dashboard|form)\b') {
        return 'ui-ux'
    }

    if ($text -match '\b(ci|cd|pipeline|deploy|deployment|infra|infrastructure|terraform|docker|container|config|configuration|environment|setup)\b') {
        return 'infrastructure'
    }

    if ($text -match '\b(refactor|cleanup|improve|improvement|enhance|optimization|optimise|optimize|streamline)\b') {
        return 'enhancement'
    }

    if ($text -match '\b(api|backend|service|core|domain|repository|database)\b') {
        return 'core'
    }

    return 'feature'
}

function Start-TaskCreation {
    param(
        [Parameter(Mandatory)] [string]$UserPrompt,
        [bool]$NeedsInterview = $false
    )
    $botRoot = $script:Config.BotRoot
    $taskCreateScript = Join-Path $botRoot "systems\mcp\tools\task-create\script.ps1"
    if (-not (Test-Path $taskCreateScript)) {
        throw "Task create tool not found: $taskCreateScript"
    }

    $normalizedPrompt = Normalize-TaskCreationPrompt -Text $UserPrompt
    $taskArgs = @{
        name = Get-TaskCreationName -Prompt $normalizedPrompt
        description = $normalizedPrompt
        category = Get-TaskCreationCategory -Prompt $normalizedPrompt
        effort = 'M'
        priority = 50
        acceptance_criteria = @()
        steps = @()
        needs_interview = $NeedsInterview
    }

    $previousProjectRoot = $global:DotbotProjectRoot
    try {
        $global:DotbotProjectRoot = $script:Config.ProjectRoot
        . $taskCreateScript
        $result = Invoke-TaskCreate -Arguments $taskArgs
    } finally {
        if ($null -ne $previousProjectRoot) {
            $global:DotbotProjectRoot = $previousProjectRoot
        } else {
            Remove-Variable -Scope Global -Name DotbotProjectRoot -ErrorAction SilentlyContinue
        }
    }

    if (Get-Command Write-Status -ErrorAction SilentlyContinue) {
        Write-Status "Task created directly in todo: $($result.task_id)" -Type Success
    }
    return $result
}

function Set-RoadmapTaskIgnore {
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [bool]$Ignored,
        [string]$Actor
    )

    Import-TaskMutationModule
    $actorName = Get-TaskMutationActor -Actor $Actor
    $result = Set-TaskIgnoreState -TaskId $TaskId -Ignored $Ignored -Actor $actorName -TasksBaseDir (Get-TasksBaseDir)
    return $result
}

function Update-RoadmapTask {
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [object]$Updates,
        [string]$Actor
    )

    Import-TaskMutationModule
    $actorName = Get-TaskMutationActor -Actor $Actor
    $updateHash = ConvertTo-TaskApiHashtable -InputObject $Updates
    return Update-TaskContent -TaskId $TaskId -Updates $updateHash -Actor $actorName -TasksBaseDir (Get-TasksBaseDir)
}

function Delete-RoadmapTask {
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [string]$Actor
    )

    Import-TaskMutationModule
    $actorName = Get-TaskMutationActor -Actor $Actor
    return Remove-TaskFromTodo -TaskId $TaskId -Actor $actorName -TasksBaseDir (Get-TasksBaseDir)
}

function Get-RoadmapTaskHistory {
    param(
        [Parameter(Mandatory)] [string]$TaskId
    )

    Import-TaskMutationModule
    $history = Get-TaskVersionHistory -TaskId $TaskId -TasksBaseDir (Get-TasksBaseDir)

    return @{
        success = $true
        task_id = $TaskId
        edited_versions = @($history.edited_versions)
        deleted_versions = @($history.deleted_versions)
    }
}

function Get-DeletedRoadmapTasks {
    $activeTodoTaskIds = Get-ActiveTodoTaskIds
    $allDeletedVersions = @(
        Get-DeletedArchiveVersions | ForEach-Object {
            Add-DeletedArchiveRestoreState -Version $_ -ActiveTaskIds $activeTodoTaskIds
        }
    )
    $latestDeletedTasks = @(
        $allDeletedVersions |
            Group-Object -Property task_id |
            ForEach-Object {
                $_.Group | Sort-Object { try { if ($_.captured_at) { [DateTime]$_.captured_at } else { [DateTime]::MinValue } } catch { [DateTime]::MinValue } } -Descending | Select-Object -First 1
            } |
            Sort-Object { try { if ($_.captured_at) { [DateTime]$_.captured_at } else { [DateTime]::MinValue } } catch { [DateTime]::MinValue } } -Descending
    )

    return @{
        success = $true
        deleted_versions = $allDeletedVersions
        latest_deleted_tasks = $latestDeletedTasks
        count = $allDeletedVersions.Count
        latest_count = $latestDeletedTasks.Count
    }
}

function Restore-RoadmapTaskVersion {
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [string]$VersionId,
        [string]$Actor
    )

    Import-TaskMutationModule
    $actorName = Get-TaskMutationActor -Actor $Actor
    return Restore-TaskVersion -TaskId $TaskId -VersionId $VersionId -Actor $actorName -TasksBaseDir (Get-TasksBaseDir)
}

Export-ModuleMember -Function @(
    'Initialize-TaskAPI',
    'Get-TaskPlan',
    'Get-ActionRequired',
    'Submit-TaskAnswer',
    'Submit-SplitApproval',
    'Start-TaskCreation',
    'Set-RoadmapTaskIgnore',
    'Update-RoadmapTask',
    'Delete-RoadmapTask',
    'Get-RoadmapTaskHistory',
    'Get-DeletedRoadmapTasks',
    'Restore-RoadmapTaskVersion'
)
