# Logging.Tests.ps1
# Pester 5.x coverage for src/lib/Logging.ps1.

BeforeAll {
    $script:RepoRoot = Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'src/lib/Logging.ps1')
}

Describe 'New-LogContext' {

    It 'creates the log root if it does not exist and returns a context with a resolved log path' {
        $tempRoot = Join-Path -Path $TestDrive -ChildPath 'logs with spaces'
        $ctx = New-LogContext -LogRoot $tempRoot -RunId 'unittest'
        try {
            (Test-Path -LiteralPath $tempRoot) | Should -BeTrue
            (Test-Path -LiteralPath $ctx.LogPath) | Should -BeTrue
            $ctx.RunId | Should -Be 'unittest'
            $ctx.LogPath | Should -Match 'chrysalis-\d{8}-\d{6}-unittest\.log$'
        } finally {
            Close-LogContext -Context $ctx
        }
    }

    It 'generates a random RunId when -RunId is omitted' {
        $tempRoot = Join-Path -Path $TestDrive -ChildPath 'logs-random'
        $ctx = New-LogContext -LogRoot $tempRoot
        try {
            $ctx.RunId | Should -Match '^[0-9a-f]{8}$'
        } finally {
            Close-LogContext -Context $ctx
        }
    }

    It 'writes a session-start line as soon as the context is created' {
        $tempRoot = Join-Path -Path $TestDrive -ChildPath 'logs-start'
        $ctx = New-LogContext -LogRoot $tempRoot -RunId 'startline'
        try {
            $lines = Get-Content -LiteralPath $ctx.LogPath
            ($lines -join "`n") | Should -Match 'Session start. RunId=startline'
        } finally {
            Close-LogContext -Context $ctx
        }
    }

    It 'throws a clear error when the log root cannot be created' {
        # Point at a path under an existing file — directory creation must fail.
        $blocker = Join-Path -Path $TestDrive -ChildPath 'blocker.txt'
        Set-Content -LiteralPath $blocker -Value 'not a directory'
        $bogus = Join-Path -Path $blocker -ChildPath 'logs'
        { New-LogContext -LogRoot $bogus -RunId 'fail' } | Should -Throw -ExpectedMessage '*cannot create log root*'
    }
}

Describe 'Write-Log' {

    BeforeEach {
        $script:tempRoot = Join-Path -Path $TestDrive -ChildPath ('write-' + [guid]::NewGuid().ToString('N'))
        $script:ctx = New-LogContext -LogRoot $script:tempRoot -RunId 'writetest'
    }

    AfterEach {
        if ($script:ctx -and -not $script:ctx.Closed) {
            Close-LogContext -Context $script:ctx
        }
    }

    It 'writes Info lines with ISO-8601 timestamps' {
        Write-Log -Context $script:ctx -Severity Info -Message 'hello info'
        Close-LogContext -Context $script:ctx
        $content = Get-Content -LiteralPath $script:ctx.LogPath -Raw
        $content | Should -Match '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+\-]\d{2}:\d{2} \[INFO\] hello info'
    }

    It 'writes Warn lines tagged WARN' {
        Write-Log -Context $script:ctx -Severity Warn -Message 'careful now' -WarningAction SilentlyContinue
        Close-LogContext -Context $script:ctx
        $content = Get-Content -LiteralPath $script:ctx.LogPath -Raw
        $content | Should -Match '\[WARN\] careful now'
    }

    It 'writes Error lines tagged ERROR' {
        Write-Log -Context $script:ctx -Severity Error -Message 'something broke'
        Close-LogContext -Context $script:ctx
        $content = Get-Content -LiteralPath $script:ctx.LogPath -Raw
        $content | Should -Match '\[ERROR\] something broke'
    }

    It 'writes Remediation lines tagged REMEDIATION' {
        Write-Log -Context $script:ctx -Severity Remediation -Message 'Run fmsadmin backup, then re-run chrysalis.'
        Close-LogContext -Context $script:ctx
        $content = Get-Content -LiteralPath $script:ctx.LogPath -Raw
        $content | Should -Match '\[REMEDIATION\] Run fmsadmin backup, then re-run chrysalis\.'
    }

    It 'rejects an unknown severity' {
        { Write-Log -Context $script:ctx -Severity 'Trace' -Message 'nope' } | Should -Throw
    }

    It 'rejects a null context' {
        { Write-Log -Context $null -Severity Info -Message 'x' } | Should -Throw
    }
}

Describe 'Close-LogContext' {

    It 'writes a session-end line with elapsed seconds and marks the context closed' {
        $tempRoot = Join-Path -Path $TestDrive -ChildPath 'logs-close'
        $ctx = New-LogContext -LogRoot $tempRoot -RunId 'closetest'
        Write-Log -Context $ctx -Severity Info -Message 'work happening'
        Close-LogContext -Context $ctx

        $ctx.Closed | Should -BeTrue
        $content = Get-Content -LiteralPath $ctx.LogPath -Raw
        $content | Should -Match 'Session end\. Elapsed=\d+\.\d{3}s'
    }

    It 'is idempotent when called twice' {
        $tempRoot = Join-Path -Path $TestDrive -ChildPath 'logs-idem'
        $ctx = New-LogContext -LogRoot $tempRoot -RunId 'idem'
        Close-LogContext -Context $ctx
        { Close-LogContext -Context $ctx } | Should -Not -Throw
    }

    It 'refuses further writes after close' {
        $tempRoot = Join-Path -Path $TestDrive -ChildPath 'logs-afterclose'
        $ctx = New-LogContext -LogRoot $tempRoot -RunId 'afterclose'
        Close-LogContext -Context $ctx
        { Write-Log -Context $ctx -Severity Info -Message 'should fail' } | Should -Throw -ExpectedMessage '*already closed*'
    }
}
